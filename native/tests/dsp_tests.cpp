#include "ses.h"
#include "../src/clock.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <vector>
#include <chrono>
#include <cstdlib>
#include <string_view>

static int failures=0, checks=0;
static void check(bool value,const char* name) { ++checks; if (!value) { ++failures; std::printf("FAIL %s\n",name); } }
static float peak(const std::vector<float>& v) { float p=0; for(float x:v) p=std::max(p,std::abs(x)); return p; }
static float rms(const std::vector<float>& v,size_t start=0) { double sum=0; for(size_t i=start;i<v.size();++i) sum+=v[i]*v[i]; return std::sqrt(sum/std::max<size_t>(1,v.size()-start)); }
static std::vector<float> tone(float amplitude,unsigned seconds=2,float hz=180) { std::vector<float> x(seconds*SES_RATE); for(size_t i=0;i<x.size();++i) x[i]=amplitude*std::sin(6.28318530718*hz*i/SES_RATE); return x; }
static std::vector<float> process(const std::vector<float>& x,const SesDspConfig& c) {
    auto* e=ses_create(); check(e!=nullptr,"engine creates"); check(ses_update(e,&c)==0,"config accepted"); std::vector<float> y(x.size());
    check(ses_process(e,x.data(),y.data(),static_cast<uint32_t>(x.size()))==0,"offline process succeeds"); ses_destroy(e); return y;
}
int main(int argc,char** argv) {
    SesDspConfig c{}; ses_default_config(&c); check(ses_abi_version()==1,"ABI version"); check(ses_config_size()==sizeof(c),"config layout");
    c.noise_enabled=0; c.agc_enabled=0; c.highpass_hz=20; c.compressor_ratio=1;
    auto loud=tone(4); auto limited=process(loud,c); check(peak(limited)<=0.891252f,"limiter ceiling even overloaded input");
    c.bypass=1; auto by=process(loud,c); check(peak(by)<=0.891252f,"bypass preserves limiter");
    c.muted=1; check(peak(process(tone(0.4),c))==0,"mute survives bypass"); c.muted=0; c.bypass=0;
    auto invalid=tone(0.1); invalid[100]=std::numeric_limits<float>::infinity(); invalid[101]=std::numeric_limits<float>::quiet_NaN();
    auto finite=process(invalid,c); check(std::all_of(finite.begin(),finite.end(),[](float x){return std::isfinite(x);}),"invalid input cannot contaminate output");
    auto invalidConfig=c; invalidConfig.bands[0].frequency=std::numeric_limits<float>::quiet_NaN(); check(ses_validate_config(&invalidConfig)!=0,"reject NaN settings");
    invalidConfig=c; invalidConfig.compressor_ratio=0; check(ses_validate_config(&invalidConfig)!=0,"reject zero compressor ratio");
    invalidConfig=c; invalidConfig.version=999; check(ses_validate_config(&invalidConfig)!=0,"reject incompatible ABI");
    auto* e=ses_create(); c.agc_enabled=1; c.noise_floor_db=-65; check(ses_update(e,&c)==0,"AGC config");
    std::vector<float> silence(SES_RATE*6),out(silence.size()); ses_process(e,silence.data(),out.data(),static_cast<uint32_t>(silence.size()));
    SesMetrics m{}; ses_read_metrics(e,&m); check(std::abs(m.gain_db)<0.01f,"AGC does not grow during silence"); check(peak(out)==0,"silence remains silence"); ses_destroy(e);
    c.agc_enabled=0; c.compressor_ratio=4; c.compressor_threshold_db=-24;
    auto compressed=process(tone(0.7,4),c); check(rms(compressed,SES_RATE*3)<0.15f,"compressor reduces sustained loud speech");
    c.compressor_ratio=1; c.highpass_hz=100; auto low=process(tone(0.2,2,20),c); auto mid=process(tone(0.2,2,1000),c);
    check(rms(low,SES_RATE)<rms(mid,SES_RATE)*0.1f,"highpass removes low rumble");
    c.highpass_hz=20; c.noise_enabled=1; c.noise_mix=1;
    std::vector<float> noise(SES_RATE*3); uint32_t seed=42; for(auto& x:noise){seed=1664525*seed+1013904223; x=(static_cast<float>(seed)/4294967295.f-0.5f)*0.02f;}
    auto cleaned=process(noise,c); check(rms(cleaned,SES_RATE*2)<rms(noise,SES_RATE*2)*0.8f,"RNNoise suppresses stationary noise");
    c.noise_enabled=0; c.bypass=1; auto sample=tone(0.3,1,997.13f); auto delayed=process(sample,c);
    check(std::abs(delayed[1500]-sample[540])<0.0001f,"dry path aligned by two RNNoise frames");
    // Non-periodic chirp detects a hidden extra RNNoise frame that a fixed tone can mask.
    auto chirp=tone(.2f,3);double phase=0;for(size_t i=0;i<chirp.size();++i){phase+=6.28318530718*(350+240.*i/SES_RATE)/SES_RATE;chirp[i]=.2f*float(std::sin(phase));}
    c.bypass=0;c.noise_enabled=1;c.noise_mix=1;auto wet=process(chirp,c);double dot=0,aa=0,bb=0;
    for(size_t i=SES_RATE;i<wet.size();++i){dot+=wet[i]*chirp[i-960];aa+=wet[i]*wet[i];bb+=chirp[i-960]*chirp[i-960];}
    check(dot/std::sqrt(aa*bb)>.8,"RNNoise and delayed dry share verified 960-sample alignment");
    auto* transition=ses_create();ses_update(transition,&c);std::vector<float> block(480),result(480);float previous=0,jump=0;
    for(unsigned b=0;b<250;++b){for(unsigned i=0;i<480;++i)block[i]=.2f*std::sin(6.28318530718*173.3*(b*480+i)/SES_RATE);if(b==200){c.noise_enabled=0;ses_update(transition,&c);}ses_process(transition,block.data(),result.data(),480);if(b>=200&&b<=210){jump=std::max(jump,std::abs(result[0]-previous));for(unsigned i=1;i<480;++i)jump=std::max(jump,std::abs(result[i]-result[i-1]));}previous=result.back();}
    check(jump<.015,"noise switch has no discontinuity on ongoing voice tone");ses_destroy(transition);
    for(double ppm:{-600.,600.}){double fill=960;bool stable=true;for(unsigned step=0;step<360000;++step){fill+=480*(1+ppm/1e6);fill-=480*ses::clock_ratio(fill,960);if(fill<2||fill>8190)stable=false;}check(stable,"one-hour virtual clock drift remains bounded at +/-600 ppm");}
    transition=ses_create();c.noise_enabled=0;c.output_db=0;ses_update(transition,&c);previous=0;jump=0;
    for(unsigned b=0;b<250;++b){for(unsigned i=0;i<480;++i)block[i]=.1f*std::sin(6.28318530718*173.3*(b*480+i)/SES_RATE);if(b==200){c.output_db=12;ses_update(transition,&c);}ses_process(transition,block.data(),result.data(),480);if(b>=200&&b<=210){jump=std::max(jump,std::abs(result[0]-previous));for(unsigned i=1;i<480;++i)jump=std::max(jump,std::abs(result[i]-result[i-1]));}previous=result.back();}
    check(jump<.015,"output gain ramps at sample rate without clicks");ses_destroy(transition);
    auto* fuzz=ses_create();uint32_t random=1337;bool bounded=true;
    for(unsigned trial=0;trial<300;++trial){ses_default_config(&c);c.noise_enabled=trial%2;c.agc_enabled=trial%3!=0;c.output_db=12;for(auto& band:c.bands){random=1664525*random+1013904223;band.frequency=20+(random%19981);band.gain_db=float(int(random%25)-12);band.q=.2f+float(random%980)/100;}ses_update(fuzz,&c);for(auto& x:block){random=1664525*random+1013904223;x=float(int(random%1000)-500)/50;}ses_process(fuzz,block.data(),result.data(),480);for(auto x:result)if(!std::isfinite(x)||std::abs(x)>.891252f)bounded=false;}
    check(bounded,"adversarial legal filters and overloaded samples remain finite and bounded");ses_destroy(fuzz);
    auto* empty=ses_create(); float dest[8]{}; check(ses_copy_sample(empty,0,dest,8)==0,"no audio recorded implicitly"); check(ses_begin_sample(empty,21)!=0,"sample limit enforced"); ses_destroy(empty);
    if(argc>1 && std::string_view(argv[1])=="--benchmark") {
        auto* b=ses_create(); ses_default_config(&c); ses_update(b,&c); auto x=tone(0.15,60,220); std::vector<float> y(x.size());
        auto begin=std::chrono::steady_clock::now(); ses_process(b,x.data(),y.data(),static_cast<uint32_t>(x.size())); auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
        std::printf("BENCHMARK audio_seconds=60 wall_ms=%.2f one_core_realtime_percent=%.2f\n",ms,ms/600); ses_destroy(b);
    }
    std::printf("%d checks, %d failures\n",checks,failures); return failures?1:0;
}
