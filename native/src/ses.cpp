#include "ses.h"
#include "dsp.hpp"
#include "audio_fifo.hpp"
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
#include "driver_bridge.hpp"
#include <mmdeviceapi.h>
#include <propvarutil.h>

namespace {
using Clock=std::chrono::steady_clock;
int64_t now(){return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();}
bool range(float n,float low,float high){return std::isfinite(n)&&n>=low&&n<=high;}
template<size_t N> void utf8(char(&dest)[N],const wchar_t* source){dest[0]=0;WideCharToMultiByte(CP_UTF8,0,source,-1,dest,int(N),nullptr,nullptr);dest[N-1]=0;}
constexpr unsigned config_words=sizeof(SesDspConfig)/4;
static_assert(sizeof(SesDspConfig)%4==0);
bool virtualInput(const char* id){
    wchar_t wide[512]{};MultiByteToWideChar(CP_UTF8,0,id,-1,wide,512);
    HRESULT init=CoInitializeEx(nullptr,COINIT_MULTITHREADED);IMMDeviceEnumerator* enumerator=nullptr;IMMDevice* device=nullptr;IPropertyStore* store=nullptr;bool own=false;
    const PROPERTYKEY tag={{0x60717558,0x584c,0x426b,{0x9b,0x9a,0xe8,0x81,0x77,0x2d,0x18,0x56}},1};
    if(SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,__uuidof(IMMDeviceEnumerator),reinterpret_cast<void**>(&enumerator)))&&SUCCEEDED(enumerator->GetDevice(wide,&device))&&SUCCEEDED(device->OpenPropertyStore(STGM_READ,&store))){PROPVARIANT value{};if(SUCCEEDED(store->GetValue(tag,&value)))own=value.vt==VT_UI4&&value.ulVal==1;PropVariantClear(&value);}
    if(store)store->Release();if(device)device->Release();if(enumerator)enumerator->Release();if(SUCCEEDED(init))CoUninitialize();return own;
}
}
struct SesEngine {
    ses::Dsp dsp;
    std::mutex control;
    std::array<std::atomic<uint32_t>,config_words> words{};
    std::atomic<uint64_t> revision{0};uint64_t applied=0;
    std::atomic<uint32_t> talkGate{0};
    std::array<std::atomic<float>,12> metricFloats{};
    std::atomic<uint64_t> processed{0},clipped{0};
    std::atomic<uint32_t> underruns{0},overruns{0},error{0};
    std::atomic<bool> running{false},connected{false},recording{false};
    std::atomic<int64_t> lastCapture{0};
    ses::AudioFifo fifo;
    std::atomic<uint64_t> captureCalls{0},playbackCalls{0},captureMaxGap{0},playbackMaxGap{0},captureMaxDuration{0};
    std::atomic<uint32_t> captureMaxFrames{0},playbackMaxFrames{0},fifoMinStart{UINT32_MAX},fifoMaxStart{0},waitingCallbacks{0},underflowAvailable{0},underflowRemaining{0},refreshedWrites{0};
    std::atomic<uint32_t> capturePeriod{0},playbackPeriod{0},captureRate{0},playbackRate{0};
    Clock::time_point capturePrevious{},playbackPrevious{};
    std::array<float,SES_BLOCK> input{},output{};unsigned fill=0;
    // Reserve the entire bounded recording upfront without touching unused pages.
    // Every published sample is written before it can be copied; no uninitialized data is exposed.
    std::unique_ptr<float[]> sampleRaw,sampleWet;
    std::atomic<uint32_t> sampleFrames{0},sampleRequest{0};unsigned sampleTarget=0,sampleWrite=0;
    SesDeviceConfig devices{};
    std::atomic<uint32_t> outputKind{SES_OUTPUT_LOCAL};
    ma_context context{};ma_device capture{},playback{};
    bool contextReady=false,captureReady=false,playbackReady=false;
    std::thread supervisor;
    ses::DriverBridge bridge;
    SesEngine():sampleRaw(new float[SES_MAX_SAMPLE_FRAMES]),sampleWet(new float[SES_MAX_SAMPLE_FRAMES]){for(auto& x:metricFloats)x.store(0);metricFloats[0]=-120;metricFloats[1]=-120;SesDspConfig c;ses_default_config(&c);publish(c);}
    void publish(const SesDspConfig& c){revision.fetch_add(1,std::memory_order_acq_rel);std::array<uint32_t,config_words> data{};std::memcpy(data.data(),&c,sizeof(c));for(unsigned i=0;i<config_words;++i)words[i].store(data[i],std::memory_order_relaxed);revision.fetch_add(1,std::memory_order_release);}
    void settings(){auto before=revision.load(std::memory_order_acquire);if(before==applied||(before&1))return;std::array<uint32_t,config_words> copy{};for(unsigned i=0;i<config_words;++i)copy[i]=words[i].load(std::memory_order_relaxed);if(revision.load(std::memory_order_acquire)!=before)return;SesDspConfig c;std::memcpy(&c,copy.data(),sizeof(c));dsp.configure(c);applied=before;}
    void meters(float elapsed){const auto& m=dsp.meters;metricFloats[0]=m.input_db;metricFloats[1]=m.output_db;metricFloats[2]=m.gain_db;metricFloats[3]=m.compression_db;metricFloats[4]=m.speech_probability;metricFloats[5]=elapsed;metricFloats[8]=m.noise_mix;metricFloats[9]=m.noise_floor_db;metricFloats[10]=m.sensitivity_threshold_db;metricFloats[11]=m.sensitivity_gain;processed=m.processed_frames;clipped=m.clipped_samples;}
    void block(){
        settings();auto begin=Clock::now();dsp.block(input.data(),output.data());
        // Snapshot both fields together. Config updates cannot reopen this gate.
        const auto gate=talkGate.load(std::memory_order_acquire),mode=gate&3u;const bool held=(gate&4u)!=0;
        if((mode==1&&!held)||(mode==2&&held)){output.fill(0);dsp.meters.output_db=-120;}
        meters(std::chrono::duration<float,std::milli>(Clock::now()-begin).count());
    }
};
template<class T> static void maximum(std::atomic<T>& value,T candidate){auto old=value.load(std::memory_order_relaxed);while(old<candidate&&!value.compare_exchange_weak(old,candidate,std::memory_order_relaxed)){} }
static void callbackGap(Clock::time_point begin,Clock::time_point& previous,std::atomic<uint64_t>& maximumGap){if(previous!=Clock::time_point{})maximum(maximumGap,uint64_t(std::chrono::duration_cast<std::chrono::microseconds>(begin-previous).count()));previous=begin;}
static void notify(const ma_device_notification* n){auto* e=static_cast<SesEngine*>(n->pDevice->pUserData);if(e && e->running && (n->type==ma_device_notification_type_stopped||n->type==ma_device_notification_type_interruption_began||n->type==ma_device_notification_type_rerouted)){e->connected=false;e->error=3;}}
static void captureCallback(ma_device* device,void*,const void* data,ma_uint32 frames){
    auto* e=static_cast<SesEngine*>(device->pUserData);if(!data||!e->running)return;
    const auto begin=Clock::now();callbackGap(begin,e->capturePrevious,e->captureMaxGap);++e->captureCalls;maximum(e->captureMaxFrames,frames);
    e->lastCapture=now();const auto* samples=static_cast<const float*>(data);
    for(unsigned i=0;i<frames;++i){e->input[e->fill++]=ses::clean(samples[i]);if(e->fill!=SES_BLOCK)continue;e->fill=0;e->block();
        unsigned request=e->sampleRequest.exchange(0,std::memory_order_acquire);if(request){e->sampleTarget=request;e->sampleWrite=0;e->sampleFrames=0;}
        if(e->recording && e->sampleWrite<e->sampleTarget){unsigned n=std::min<unsigned>(SES_BLOCK,e->sampleTarget-e->sampleWrite);std::memcpy(e->sampleRaw.get()+e->sampleWrite,e->input.data(),n*sizeof(float));std::memcpy(e->sampleWet.get()+e->sampleWrite,e->output.data(),n*sizeof(float));e->sampleWrite+=n;e->sampleFrames.store(e->sampleWrite,std::memory_order_release);if(e->sampleWrite>=e->sampleTarget)e->recording=false;}
        if(e->devices.output_kind==SES_OUTPUT_DRIVER)e->bridge.push(e->output.data());
        if(e->playbackReady&&!e->fifo.write(e->output.data(),SES_BLOCK))++e->overruns;
    }
    maximum(e->captureMaxDuration,uint64_t(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-begin).count()));
}
static void playbackCallback(ma_device* device,void* data,const void*,ma_uint32 frames){
    auto* e=static_cast<SesEngine*>(device->pUserData);auto* output=static_cast<float*>(data);std::fill_n(output,frames,0.f);
    if(!e->running||!e->connected)return;
    callbackGap(Clock::now(),e->playbackPrevious,e->playbackMaxGap);++e->playbackCalls;maximum(e->playbackMaxFrames,frames);
    const auto result=e->fifo.readBuffered(output,frames,e->devices.buffer_ms*48);
    maximum(e->fifoMaxStart,result.startingFill);auto old=e->fifoMinStart.load(std::memory_order_relaxed);while(old>result.startingFill&&!e->fifoMinStart.compare_exchange_weak(old,result.startingFill,std::memory_order_relaxed)){}
    if(result.waiting)++e->waitingCallbacks;
    if(result.underrun){++e->underruns;e->underflowAvailable=result.underflowAvailable;e->underflowRemaining=result.underflowRemaining;}
    e->refreshedWrites.fetch_add(result.refreshedWrites,std::memory_order_relaxed);
    e->metricFloats[7]=float((result.ratio-1)*1e6);e->metricFloats[6]=20.f+result.startingFill/48.f;
}
static void closeDevices(SesEngine* e){if(e->captureReady){ma_device_uninit(&e->capture);e->captureReady=false;}if(e->playbackReady){ma_device_uninit(&e->playback);e->playbackReady=false;}e->connected=false;}
static int openDevices(SesEngine* e){
    ma_device_info *renders=nullptr,*inputs=nullptr;ma_uint32 rn=0,in=0;
    if(ma_context_get_devices(&e->context,&renders,&rn,&inputs,&in)!=MA_SUCCESS)return -3;
    ma_device_id inputID{},outputID{};bool foundInput=false,foundOutput=e->devices.output_kind!=SES_OUTPUT_WASAPI;
    for(unsigned i=0;i<in;++i){char id[512];utf8(id,inputs[i].id.wasapi);if(std::strcmp(id,e->devices.input_id)==0){inputID=inputs[i].id;foundInput=true;break;}}
    for(unsigned i=0;i<rn;++i){char id[512];utf8(id,renders[i].id.wasapi);if(std::strcmp(id,e->devices.output_id)==0){outputID=renders[i].id;foundOutput=true;break;}}
    if(!foundInput||!foundOutput){e->error=3;return -3;}
    e->fill=0;e->fifo.reset();e->capturePrevious={};e->playbackPrevious={};e->dsp.reset();e->applied=0;e->settings();e->meters(0);
    if(e->devices.output_kind==SES_OUTPUT_WASAPI){auto config=ma_device_config_init(ma_device_type_playback);config.playback.pDeviceID=&outputID;config.playback.format=ma_format_f32;config.playback.channels=1;config.playback.shareMode=ma_share_mode_shared;config.sampleRate=SES_RATE;config.periodSizeInMilliseconds=e->devices.period_ms;config.dataCallback=playbackCallback;config.notificationCallback=notify;config.pUserData=e;if(ma_device_init(&e->context,&config,&e->playback)!=MA_SUCCESS)return -3;e->playbackReady=true;}
    auto config=ma_device_config_init(ma_device_type_capture);config.capture.pDeviceID=&inputID;config.capture.format=ma_format_f32;config.capture.channels=1;config.capture.shareMode=ma_share_mode_shared;config.sampleRate=SES_RATE;config.periodSizeInMilliseconds=e->devices.period_ms;config.dataCallback=captureCallback;config.notificationCallback=notify;config.pUserData=e;
    auto captureResult=ma_device_init(&e->context,&config,&e->capture);if(captureResult!=MA_SUCCESS){e->error=captureResult==MA_ACCESS_DENIED?4u:5u;closeDevices(e);return captureResult==MA_ACCESS_DENIED?-4:-5;}e->captureReady=true;e->connected=true;e->lastCapture=now();
    e->capturePeriod=e->capture.capture.internalPeriodSizeInFrames;e->captureRate=e->capture.capture.internalSampleRate;
    e->playbackPeriod=e->playbackReady?e->playback.playback.internalPeriodSizeInFrames:0;e->playbackRate=e->playbackReady?e->playback.playback.internalSampleRate:0;
    if(ma_device_start(&e->capture)!=MA_SUCCESS || (e->playbackReady && ma_device_start(&e->playback)!=MA_SUCCESS)){closeDevices(e);return -3;}e->error=0;return 0;
}
uint32_t ses_abi_version(){return SES_ABI_VERSION;}
uint32_t ses_config_size(){return sizeof(SesDspConfig);}
uint32_t ses_metrics_size(){return sizeof(SesMetrics);}
void ses_default_config(SesDspConfig* c){if(!c)return;*c={};c->version=SES_ABI_VERSION;c->size=sizeof(*c);c->noise_enabled=1;c->agc_enabled=1;c->highpass_hz=80;c->noise_mix=.65f;c->target_db=-20;c->min_gain_db=-12;c->max_gain_db=12;c->compressor_threshold_db=-18;c->compressor_ratio=2;c->attack_ms=10;c->release_ms=120;c->knee_db=6;c->deesser_max_db=3;c->noise_floor_db=-60;c->speech_threshold=.55f;c->sensitivity_auto_enabled=1;c->sensitivity_threshold_db=-50;c->sensitivity_attack_ms=2;c->sensitivity_hold_ms=300;c->sensitivity_release_ms=120;c->sensitivity_hysteresis_db=6;c->sensitivity_ratio=2;c->sensitivity_max_reduction_db=24;c->bands[0]={1,180,0,.707f};c->bands[1]={0,600,0,1};c->bands[2]={0,3000,0,1};c->bands[3]={2,8000,0,.707f};}
int ses_validate_config(const SesDspConfig* c){
    if(!c||c->version!=SES_ABI_VERSION||c->size!=sizeof(*c))return -2;
    if(c->sensitivity_enabled>1||c->sensitivity_auto_enabled>1||c->noise_auto_enabled>1||c->noise_enabled>1||c->agc_enabled>1||c->deesser_enabled>1||c->muted>1||c->bypass>1||c->sensitivity_mode>1)return -2;
    if(!range(c->highpass_hz,20,300)||!range(c->noise_mix,0,1)||!range(c->target_db,-36,-10)||!range(c->min_gain_db,-12,0)||!range(c->max_gain_db,0,12)||!range(c->compressor_threshold_db,-48,-3)||!range(c->compressor_ratio,1,8)||!range(c->attack_ms,1,100)||!range(c->release_ms,20,1000)||!range(c->knee_db,0,12)||!range(c->deesser_max_db,0,3)||!range(c->output_db,-24,12)||!range(c->noise_floor_db,-120,-15)||!range(c->speech_threshold,0,1)||!range(c->sensitivity_threshold_db,-90,-10)||!range(c->sensitivity_attack_ms,.1f,100)||!range(c->sensitivity_hold_ms,0,2000)||!range(c->sensitivity_release_ms,5,2000)||!range(c->sensitivity_hysteresis_db,0,24)||!range(c->sensitivity_ratio,1,8)||!range(c->sensitivity_max_reduction_db,0,60))return -2;
    for(auto b:c->bands)if(b.type<0||b.type>2||!range(b.frequency,20,20000)||!range(b.gain_db,-12,12)||!range(b.q,.2f,10))return -2;
    return 0;
}
SesEngine* ses_create(){try{auto* e=new SesEngine;if(!e->dsp.ready()){delete e;return nullptr;}return e;}catch(...){return nullptr;}}
void ses_destroy(SesEngine* e){if(e){ses_stop(e);if(e->contextReady)ma_context_uninit(&e->context);delete e;}}
int ses_update(SesEngine* e,const SesDspConfig* c){if(!e||ses_validate_config(c))return -2;std::lock_guard guard(e->control);e->publish(*c);return 0;}
int ses_set_talk_gate(SesEngine* e,uint32_t mode,uint32_t held){if(!e||mode>2||held>1)return -2;e->talkGate.store(mode|(held<<2),std::memory_order_release);return 0;}
int ses_read_metrics(SesEngine* e,SesMetrics* m){if(!e||!m)return -2;*m={};m->input_db=e->metricFloats[0];m->output_db=e->metricFloats[1];m->gain_db=e->metricFloats[2];m->compression_db=e->metricFloats[3];m->speech_probability=e->metricFloats[4];m->processing_ms=e->metricFloats[5];m->estimated_buffer_ms=e->metricFloats[6];m->drift_ppm=e->metricFloats[7];m->noise_mix=e->metricFloats[8];m->noise_floor_db=e->metricFloats[9];m->sensitivity_threshold_db=e->metricFloats[10];m->sensitivity_gain=e->metricFloats[11];m->processed_frames=e->processed;m->clipped_samples=e->clipped;m->running=e->running;m->connected=e->connected;m->underruns=e->underruns;m->overruns=e->overruns;m->sample_frames=e->sampleFrames;m->error_code=e->error;m->output_kind=e->outputKind;m->driver_status=e->bridge.status;m->driver_protocol=e->bridge.protocol;m->driver_error=e->bridge.lastError;m->driver_queued_frames=e->bridge.queued;m->driver_underruns=e->bridge.underruns;m->driver_overruns=e->bridge.overruns;m->driver_drift_ppm=e->bridge.drift;m->driver_sent_frames=e->bridge.sent;m->driver_silence_frames=e->bridge.silence;
    if(m->output_kind==SES_OUTPUT_DRIVER){m->estimated_buffer_ms=e->bridge.status==2?e->bridge.bufferMs():20.f;m->overruns+=e->bridge.queueDrops;}else if(m->output_kind==SES_OUTPUT_LOCAL)m->estimated_buffer_ms=20.f;return 0;}
int ses_process(SesEngine* e,const float* x,float* y,uint32_t n){if(!e||!x||!y||n%SES_BLOCK||e->running)return -2;std::lock_guard guard(e->control);for(unsigned i=0;i<n;i+=SES_BLOCK){std::memcpy(e->input.data(),x+i,SES_BLOCK*sizeof(float));e->block();std::memcpy(y+i,e->output.data(),SES_BLOCK*sizeof(float));}return 0;}
int ses_read_stream_diagnostics(SesEngine* e,uint32_t version,uint32_t size,SesStreamDiagnostics* d){
    if(!e||!d||version!=SES_STREAM_DIAGNOSTICS_VERSION||size!=sizeof(*d))return -2;
    *d={};d->version=version;d->size=size;d->capture_callbacks=e->captureCalls;d->playback_callbacks=e->playbackCalls;
    d->capture_max_gap_us=e->captureMaxGap;d->playback_max_gap_us=e->playbackMaxGap;d->capture_max_duration_us=e->captureMaxDuration;
    d->capture_max_frames=e->captureMaxFrames;d->playback_max_frames=e->playbackMaxFrames;auto minimum=e->fifoMinStart.load();d->fifo_min_starting_frames=minimum==UINT32_MAX?0:minimum;d->fifo_max_starting_frames=e->fifoMaxStart;
    d->waiting_callbacks=e->waitingCallbacks;d->last_underflow_available_frames=e->underflowAvailable;d->last_underflow_remaining_frames=e->underflowRemaining;d->refreshed_writes=e->refreshedWrites;
    d->capture_period_frames=e->capturePeriod;d->playback_period_frames=e->playbackPeriod;d->capture_device_rate=e->captureRate;d->playback_device_rate=e->playbackRate;return 0;
}
int ses_list_devices(SesDevice* devices,uint32_t capacity,uint32_t* count){
    if(!count||(!devices&&capacity))return -2;ma_context context{};ma_backend backend=ma_backend_wasapi;if(ma_context_init(&backend,1,nullptr,&context)!=MA_SUCCESS)return -3;
    ma_device_info *outputs=nullptr,*inputs=nullptr;ma_uint32 on=0,in=0;int result=0;
    if(ma_context_get_devices(&context,&outputs,&on,&inputs,&in)!=MA_SUCCESS)result=-3;else{*count=on+in;for(unsigned i=0;i<std::min<unsigned>(capacity,on+in);++i){auto* info=i<in?&inputs[i]:&outputs[i-in];devices[i]={};utf8(devices[i].id,info->id.wasapi);std::strncpy(devices[i].name,info->name,511);devices[i].kind=i<in?0u:1u;devices[i].is_default=info->isDefault;devices[i].is_ses_virtual=i<in&&(virtualInput(devices[i].id)||std::strcmp(devices[i].name,"SES Mikrofon")==0);}}
    ma_context_uninit(&context);return result;
}
int ses_start(SesEngine* e,const SesDeviceConfig* c){
    if(!e||!c||c->version!=SES_ABI_VERSION||c->size!=sizeof(*c)||!c->input_id[0]||!std::memchr(c->input_id,0,512)||!std::memchr(c->output_id,0,512)||c->period_ms<5||c->period_ms>30||c->buffer_ms<10||c->buffer_ms>60||c->output_kind>SES_OUTPUT_WASAPI||(c->output_kind!=SES_OUTPUT_WASAPI&&c->output_id[0]))return -2;
    if(virtualInput(c->input_id))return -2;
    ses_stop(e);std::lock_guard guard(e->control);e->devices=*c;e->outputKind=c->output_kind;
    e->captureCalls=0;e->playbackCalls=0;e->captureMaxGap=0;e->playbackMaxGap=0;e->captureMaxDuration=0;e->captureMaxFrames=0;e->playbackMaxFrames=0;e->fifoMinStart=UINT32_MAX;e->fifoMaxStart=0;e->waitingCallbacks=0;e->underflowAvailable=0;e->underflowRemaining=0;e->refreshedWrites=0;e->capturePeriod=0;e->playbackPeriod=0;e->captureRate=0;e->playbackRate=0;
    if(!e->contextReady){ma_backend backend=ma_backend_wasapi;if(ma_context_init(&backend,1,nullptr,&e->context)!=MA_SUCCESS)return -3;e->contextReady=true;}
    e->running=true;int result=openDevices(e);if(result && result!=-3){e->running=false;return result;}
    if(c->output_kind==SES_OUTPUT_DRIVER)e->bridge.start();
    try {e->supervisor=std::thread([e]{while(e->running){std::this_thread::sleep_for(std::chrono::milliseconds(250));if(!e->running)break;if(!e->connected||now()-e->lastCapture.load()>2000){std::lock_guard lock(e->control);closeDevices(e);if(e->running)openDevices(e);}}});}catch(...){e->running=false;closeDevices(e);e->bridge.stop();return -1;}return 0;
}
void ses_stop(SesEngine* e){if(!e)return;e->running=false;e->recording=false;if(e->supervisor.joinable())e->supervisor.join();std::lock_guard guard(e->control);closeDevices(e);e->bridge.stop();}
int ses_begin_sample(SesEngine* e,uint32_t seconds){if(!e||!e->running||seconds==0||seconds>20||e->recording.exchange(true))return -2;e->sampleFrames=0;e->sampleRequest.store(seconds*SES_RATE,std::memory_order_release);return 0;}
void ses_end_sample(SesEngine* e){if(e)e->recording=false;}
uint32_t ses_copy_sample(SesEngine* e,uint32_t which,float* output,uint32_t capacity){if(!e||!output||which>1)return 0;auto n=std::min(capacity,e->sampleFrames.load(std::memory_order_acquire));std::memcpy(output,(which?e->sampleWet:e->sampleRaw).get(),n*sizeof(float));return n;}
