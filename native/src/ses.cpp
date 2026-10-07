#include "ses.h"
#include "dsp.hpp"
#include "clock.hpp"
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_WASAPI
#include "miniaudio.h"
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>
#include <memory>
#include <bit>

namespace {
using Clock=std::chrono::steady_clock;
int64_t now(){return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();}
bool range(float n,float low,float high){return std::isfinite(n)&&n>=low&&n<=high;}
template<size_t N> void utf8(char(&dest)[N],const wchar_t* source){dest[0]=0;WideCharToMultiByte(CP_UTF8,0,source,-1,dest,int(N),nullptr,nullptr);dest[N-1]=0;}
constexpr unsigned ring_size=8192,config_words=sizeof(SesDspConfig)/4;
static_assert(sizeof(SesDspConfig)%4==0);
}
struct SesEngine {
    ses::Dsp dsp;
    std::mutex control;
    std::array<std::atomic<uint32_t>,config_words> words{};
    std::atomic<uint64_t> revision{0};uint64_t applied=0;
    std::array<std::atomic<float>,8> metricFloats{};
    std::atomic<uint64_t> processed{0},clipped{0};
    std::atomic<uint32_t> underruns{0},overruns{0},error{0};
    std::atomic<bool> running{false},connected{false},recording{false};
    std::atomic<int64_t> lastCapture{0};
    std::array<float,ring_size> ring{};
    std::atomic<uint64_t> write{0},read{0};double fraction=0;bool primed=false;
    std::array<float,SES_BLOCK> input{},output{};unsigned fill=0;
    // Reserve the entire bounded recording upfront without touching unused pages.
    // Every published sample is written before it can be copied; no uninitialized data is exposed.
    std::unique_ptr<float[]> sampleRaw,sampleWet;
    std::atomic<uint32_t> sampleFrames{0},sampleRequest{0};unsigned sampleTarget=0,sampleWrite=0;
    SesDeviceConfig devices{};
    ma_context context{};ma_device capture{},playback{};
    bool contextReady=false,captureReady=false,playbackReady=false;
    std::thread supervisor;
    SesEngine():sampleRaw(new float[SES_MAX_SAMPLE_FRAMES]),sampleWet(new float[SES_MAX_SAMPLE_FRAMES]){for(auto& x:metricFloats)x.store(0);metricFloats[0]=-120;metricFloats[1]=-120;SesDspConfig c;ses_default_config(&c);publish(c);}
    void publish(const SesDspConfig& c){revision.fetch_add(1,std::memory_order_acq_rel);std::array<uint32_t,config_words> data{};std::memcpy(data.data(),&c,sizeof(c));for(unsigned i=0;i<config_words;++i)words[i].store(data[i],std::memory_order_relaxed);revision.fetch_add(1,std::memory_order_release);}
    void settings(){auto before=revision.load(std::memory_order_acquire);if(before==applied||(before&1))return;std::array<uint32_t,config_words> copy{};for(unsigned i=0;i<config_words;++i)copy[i]=words[i].load(std::memory_order_relaxed);if(revision.load(std::memory_order_acquire)!=before)return;SesDspConfig c;std::memcpy(&c,copy.data(),sizeof(c));dsp.configure(c);applied=before;}
    void meters(float elapsed){const auto& m=dsp.meters;metricFloats[0]=m.input_db;metricFloats[1]=m.output_db;metricFloats[2]=m.gain_db;metricFloats[3]=m.compression_db;metricFloats[4]=m.speech_probability;metricFloats[5]=elapsed;processed=m.processed_frames;clipped=m.clipped_samples;}
    void block(){settings();auto begin=Clock::now();dsp.block(input.data(),output.data());meters(std::chrono::duration<float,std::milli>(Clock::now()-begin).count());}
};
static void notify(const ma_device_notification* n){auto* e=static_cast<SesEngine*>(n->pDevice->pUserData);if(e && e->running && (n->type==ma_device_notification_type_stopped||n->type==ma_device_notification_type_interruption_began||n->type==ma_device_notification_type_rerouted)){e->connected=false;e->error=3;}}
static void captureCallback(ma_device* device,void*,const void* data,ma_uint32 frames){
    auto* e=static_cast<SesEngine*>(device->pUserData);if(!data||!e->running)return;
    e->lastCapture=now();const auto* samples=static_cast<const float*>(data);
    for(unsigned i=0;i<frames;++i){e->input[e->fill++]=ses::clean(samples[i]);if(e->fill!=SES_BLOCK)continue;e->fill=0;e->block();
        unsigned request=e->sampleRequest.exchange(0,std::memory_order_acquire);if(request){e->sampleTarget=request;e->sampleWrite=0;e->sampleFrames=0;}
        if(e->recording && e->sampleWrite<e->sampleTarget){unsigned n=std::min<unsigned>(SES_BLOCK,e->sampleTarget-e->sampleWrite);std::memcpy(e->sampleRaw.get()+e->sampleWrite,e->input.data(),n*sizeof(float));std::memcpy(e->sampleWet.get()+e->sampleWrite,e->output.data(),n*sizeof(float));e->sampleWrite+=n;e->sampleFrames.store(e->sampleWrite,std::memory_order_release);if(e->sampleWrite>=e->sampleTarget)e->recording=false;}
        if(e->playbackReady){uint64_t w=e->write.load(std::memory_order_relaxed),r=e->read.load(std::memory_order_acquire);if(w-r+SES_BLOCK>=ring_size){++e->overruns;continue;}for(unsigned j=0;j<SES_BLOCK;++j)e->ring[(w+j)%ring_size]=e->output[j];e->write.store(w+SES_BLOCK,std::memory_order_release);}
    }
}
static void playbackCallback(ma_device* device,void* data,const void*,ma_uint32 frames){
    auto* e=static_cast<SesEngine*>(device->pUserData);auto* output=static_cast<float*>(data);std::fill_n(output,frames,0.f);
    if(!e->running||!e->connected)return;
    uint64_t r=e->read.load(std::memory_order_relaxed),w=e->write.load(std::memory_order_acquire);unsigned target=e->devices.buffer_ms*48;
    if(!e->primed){if(w-r<target)return;e->primed=true;}
    double ratio=ses::clock_ratio(double(w-r),target);e->metricFloats[7]=float((ratio-1)*1e6);
    for(unsigned i=0;i<frames;++i){if(r+1>=w){++e->underruns;e->primed=false;e->fraction=0;break;}float a=e->ring[r%ring_size],b=e->ring[(r+1)%ring_size];output[i]=float(a+(b-a)*e->fraction);e->fraction+=ratio;unsigned advance=unsigned(e->fraction);e->fraction-=advance;r+=advance;}
    e->read.store(r,std::memory_order_release);e->metricFloats[6]=20.f+float(w-r)/48.f;
}
static void closeDevices(SesEngine* e){if(e->captureReady){ma_device_uninit(&e->capture);e->captureReady=false;}if(e->playbackReady){ma_device_uninit(&e->playback);e->playbackReady=false;}e->connected=false;}
static int openDevices(SesEngine* e){
    ma_device_info *renders=nullptr,*inputs=nullptr;ma_uint32 rn=0,in=0;
    if(ma_context_get_devices(&e->context,&renders,&rn,&inputs,&in)!=MA_SUCCESS)return -3;
    ma_device_id inputID{},outputID{};bool foundInput=false,foundOutput=!e->devices.output_id[0];
    for(unsigned i=0;i<in;++i){char id[512];utf8(id,inputs[i].id.wasapi);if(std::strcmp(id,e->devices.input_id)==0){inputID=inputs[i].id;foundInput=true;break;}}
    for(unsigned i=0;i<rn;++i){char id[512];utf8(id,renders[i].id.wasapi);if(std::strcmp(id,e->devices.output_id)==0){outputID=renders[i].id;foundOutput=true;break;}}
    if(!foundInput||!foundOutput)return -3;
    e->fill=0;e->write=0;e->read=0;e->fraction=0;e->primed=false;e->dsp.reset();e->applied=0;e->settings();
    if(e->devices.output_id[0]){auto config=ma_device_config_init(ma_device_type_playback);config.playback.pDeviceID=&outputID;config.playback.format=ma_format_f32;config.playback.channels=1;config.playback.shareMode=ma_share_mode_shared;config.sampleRate=SES_RATE;config.periodSizeInMilliseconds=e->devices.period_ms;config.dataCallback=playbackCallback;config.notificationCallback=notify;config.pUserData=e;if(ma_device_init(&e->context,&config,&e->playback)!=MA_SUCCESS)return -3;e->playbackReady=true;}
    auto config=ma_device_config_init(ma_device_type_capture);config.capture.pDeviceID=&inputID;config.capture.format=ma_format_f32;config.capture.channels=1;config.capture.shareMode=ma_share_mode_shared;config.sampleRate=SES_RATE;config.periodSizeInMilliseconds=e->devices.period_ms;config.dataCallback=captureCallback;config.notificationCallback=notify;config.pUserData=e;
    if(ma_device_init(&e->context,&config,&e->capture)!=MA_SUCCESS){closeDevices(e);return -3;}e->captureReady=true;e->connected=true;e->lastCapture=now();
    if(ma_device_start(&e->capture)!=MA_SUCCESS || (e->playbackReady && ma_device_start(&e->playback)!=MA_SUCCESS)){closeDevices(e);return -3;}e->error=0;return 0;
}
uint32_t ses_abi_version(){return SES_ABI_VERSION;}
uint32_t ses_config_size(){return sizeof(SesDspConfig);}
uint32_t ses_metrics_size(){return sizeof(SesMetrics);}
void ses_default_config(SesDspConfig* c){if(!c)return;*c={};c->version=1;c->size=sizeof(*c);c->noise_enabled=1;c->agc_enabled=1;c->highpass_hz=80;c->noise_mix=.65f;c->target_db=-20;c->min_gain_db=-12;c->max_gain_db=12;c->compressor_threshold_db=-18;c->compressor_ratio=2;c->attack_ms=10;c->release_ms=120;c->knee_db=6;c->deesser_max_db=3;c->noise_floor_db=-60;c->speech_threshold=.55f;c->bands[0]={1,180,0,.707f};c->bands[1]={0,600,0,1};c->bands[2]={0,3000,0,1};c->bands[3]={2,8000,0,.707f};}
int ses_validate_config(const SesDspConfig* c){
    if(!c||c->version!=1||c->size!=sizeof(*c))return -2;
    if(c->noise_enabled>1||c->agc_enabled>1||c->deesser_enabled>1||c->muted>1||c->bypass>1)return -2;
    if(!range(c->highpass_hz,20,300)||!range(c->noise_mix,0,1)||!range(c->target_db,-36,-10)||!range(c->min_gain_db,-12,0)||!range(c->max_gain_db,0,12)||!range(c->compressor_threshold_db,-48,-3)||!range(c->compressor_ratio,1,8)||!range(c->attack_ms,1,100)||!range(c->release_ms,20,1000)||!range(c->knee_db,0,12)||!range(c->deesser_max_db,0,3)||!range(c->output_db,-24,12)||!range(c->noise_floor_db,-120,-15)||!range(c->speech_threshold,0,1))return -2;
    for(auto b:c->bands)if(b.type<0||b.type>2||!range(b.frequency,20,20000)||!range(b.gain_db,-12,12)||!range(b.q,.2f,10))return -2;
    return 0;
}
SesEngine* ses_create(){try{auto* e=new SesEngine;if(!e->dsp.ready()){delete e;return nullptr;}return e;}catch(...){return nullptr;}}
void ses_destroy(SesEngine* e){if(e){ses_stop(e);if(e->contextReady)ma_context_uninit(&e->context);delete e;}}
int ses_update(SesEngine* e,const SesDspConfig* c){if(!e||ses_validate_config(c))return -2;std::lock_guard guard(e->control);e->publish(*c);return 0;}
int ses_read_metrics(SesEngine* e,SesMetrics* m){if(!e||!m)return -2;*m={};m->input_db=e->metricFloats[0];m->output_db=e->metricFloats[1];m->gain_db=e->metricFloats[2];m->compression_db=e->metricFloats[3];m->speech_probability=e->metricFloats[4];m->processing_ms=e->metricFloats[5];m->estimated_buffer_ms=e->metricFloats[6];m->drift_ppm=e->metricFloats[7];m->processed_frames=e->processed;m->clipped_samples=e->clipped;m->running=e->running;m->connected=e->connected;m->underruns=e->underruns;m->overruns=e->overruns;m->sample_frames=e->sampleFrames;m->error_code=e->error;return 0;}
int ses_process(SesEngine* e,const float* x,float* y,uint32_t n){if(!e||!x||!y||n%SES_BLOCK||e->running)return -2;std::lock_guard guard(e->control);for(unsigned i=0;i<n;i+=SES_BLOCK){std::memcpy(e->input.data(),x+i,SES_BLOCK*sizeof(float));e->block();std::memcpy(y+i,e->output.data(),SES_BLOCK*sizeof(float));}return 0;}
int ses_list_devices(SesDevice* devices,uint32_t capacity,uint32_t* count){
    if(!count||(!devices&&capacity))return -2;ma_context context{};ma_backend backend=ma_backend_wasapi;if(ma_context_init(&backend,1,nullptr,&context)!=MA_SUCCESS)return -3;
    ma_device_info *outputs=nullptr,*inputs=nullptr;ma_uint32 on=0,in=0;int result=0;
    if(ma_context_get_devices(&context,&outputs,&on,&inputs,&in)!=MA_SUCCESS)result=-3;else{*count=on+in;for(unsigned i=0;i<std::min<unsigned>(capacity,on+in);++i){auto* info=i<in?&inputs[i]:&outputs[i-in];devices[i]={};utf8(devices[i].id,info->id.wasapi);std::strncpy(devices[i].name,info->name,511);devices[i].kind=i<in?0u:1u;devices[i].is_default=info->isDefault;}}
    ma_context_uninit(&context);return result;
}
int ses_start(SesEngine* e,const SesDeviceConfig* c){
    if(!e||!c||c->version!=1||c->size!=sizeof(*c)||!c->input_id[0]||!std::memchr(c->input_id,0,512)||!std::memchr(c->output_id,0,512)||c->period_ms<5||c->period_ms>30||c->buffer_ms<10||c->buffer_ms>60)return -2;
    ses_stop(e);std::lock_guard guard(e->control);e->devices=*c;
    if(!e->contextReady){ma_backend backend=ma_backend_wasapi;if(ma_context_init(&backend,1,nullptr,&e->context)!=MA_SUCCESS)return -3;e->contextReady=true;}
    e->running=true;int result=openDevices(e);if(result){e->running=false;e->error=3;return result;}
    try {e->supervisor=std::thread([e]{while(e->running){std::this_thread::sleep_for(std::chrono::milliseconds(250));if(!e->running)break;if(!e->connected||now()-e->lastCapture.load()>2000){std::lock_guard lock(e->control);closeDevices(e);if(e->running)openDevices(e);}}});}catch(...){e->running=false;closeDevices(e);return -1;}return 0;
}
void ses_stop(SesEngine* e){if(!e)return;e->running=false;e->recording=false;if(e->supervisor.joinable())e->supervisor.join();std::lock_guard guard(e->control);closeDevices(e);}
int ses_begin_sample(SesEngine* e,uint32_t seconds){if(!e||!e->running||seconds==0||seconds>20||e->recording.exchange(true))return -2;e->sampleFrames=0;e->sampleRequest.store(seconds*SES_RATE,std::memory_order_release);return 0;}
void ses_end_sample(SesEngine* e){if(e)e->recording=false;}
uint32_t ses_copy_sample(SesEngine* e,uint32_t which,float* output,uint32_t capacity){if(!e||!output||which>1)return 0;auto n=std::min(capacity,e->sampleFrames.load(std::memory_order_acquire));std::memcpy(output,(which?e->sampleWet:e->sampleRaw).get(),n*sizeof(float));return n;}
