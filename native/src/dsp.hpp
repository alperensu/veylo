#pragma once
#include "ses.h"
#include "rnnoise.h"
#include "adaptive_noise.hpp"
#include "sensitivity.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace ses {
inline float db(float v) { return 20.f*std::log10(std::max(v,0.000001f)); }
inline float amp(float v) { return std::pow(10.f,v/20.f); }
inline float clean(float v) { return std::isfinite(v)?std::clamp(v,-8.f,8.f):0.f; }
struct Biquad {
    double b0=1,b1=0,b2=0,a1=0,a2=0,z1=0,z2=0;
    std::array<double,5> delta{};unsigned remaining=0;bool initialized=false;
    float tick(float x) {
        if(remaining){b0+=delta[0];b1+=delta[1];b2+=delta[2];a1+=delta[3];a2+=delta[4];--remaining;}
        double y=b0*x+z1; z1=b1*x-a1*y+z2;z2=b2*x-a2*y;
        if(!std::isfinite(y)){z1=z2=0;return 0;}
        if(std::abs(z1)<1e-20)z1=0;if(std::abs(z2)<1e-20)z2=0;
        return float(y);
    }
    void set(int type,float hz,float gain,float q) {
        const std::array<double,5> before{b0,b1,b2,a1,a2};
        const double w=6.283185307179586*hz/SES_RATE,cs=std::cos(w),sn=std::sin(w),A=std::pow(10.,gain/40.),alpha=sn/(2*q),s=2*std::sqrt(A)*alpha;
        double a0=1;
        if(type==3){ b0=(1+cs)/2;b1=-(1+cs);b2=b0;a0=1+alpha;a1=-2*cs;a2=1-alpha; }
        else if(type==0){b0=1+alpha*A;b1=-2*cs;b2=1-alpha*A;a0=1+alpha/A;a1=-2*cs;a2=1-alpha/A;}
        else if(type==1){b0=A*((A+1)-(A-1)*cs+s);b1=2*A*((A-1)-(A+1)*cs);b2=A*((A+1)-(A-1)*cs-s);a0=(A+1)+(A-1)*cs+s;a1=-2*((A-1)+(A+1)*cs);a2=(A+1)+(A-1)*cs-s;}
        else {b0=A*((A+1)+(A-1)*cs+s);b1=-2*A*((A-1)+(A+1)*cs);b2=A*((A+1)+(A-1)*cs-s);a0=(A+1)-(A-1)*cs+s;a1=2*((A-1)-(A+1)*cs);a2=(A+1)-(A-1)*cs-s;}
        b0/=a0;b1/=a0;b2/=a0;a1/=a0;a2/=a0;
        if(initialized){const std::array<double,5> after{b0,b1,b2,a1,a2};for(unsigned i=0;i<5;++i)delta[i]=(after[i]-before[i])/SES_BLOCK;b0=before[0];b1=before[1];b2=before[2];a1=before[3];a2=before[4];remaining=SES_BLOCK;}
        initialized=true;
    }
};
class Dsp {
    DenoiseState* noise=nullptr;
    SesDspConfig current{},target{};
    Biquad hp,eq[4],ess;
    AdaptiveNoise adaptiveNoise;
    Sensitivity sensitivity;
    std::array<float,SES_BLOCK> dry{},filtered{},dryNext{},filteredNext{},scaled{},wet{};
    float gain=0,compEnvelope=0,compGain=0,essEnvelope=0,limitGain=1,bypassMix=0,noiseMix=0,deesserMix=0,lastVolume=1;
    bool initial=true;
    std::array<float,2> inputLevels{-120.f,-120.f};
public:
    SesMetrics meters{};
    Dsp(){noise=rnnoise_create(nullptr);ses_default_config(&current);target=current;ess.set(3,4000,0,.707f);}
    ~Dsp(){rnnoise_destroy(noise);}
    Dsp(const Dsp&)=delete;Dsp& operator=(const Dsp&)=delete;
    bool ready()const{return noise!=nullptr;}
    void reset(){sensitivity.reset();inputLevels.fill(-120.f);rnnoise_init(noise,nullptr);dry.fill(0);filtered.fill(0);dryNext.fill(0);filteredNext.fill(0);hp={};for(auto& b:eq)b={};ess={};ess.set(3,4000,0,.707f);gain=compEnvelope=compGain=essEnvelope=bypassMix=noiseMix=deesserMix=0;limitGain=lastVolume=1;initial=true;meters={};meters.input_db=meters.output_db=-120.f;}
    void configure(const SesDspConfig& config){if(initial||config.noise_floor_db!=target.noise_floor_db)adaptiveNoise.reset(config.noise_floor_db);target=config; if(initial){current=target;bypassMix=float(target.bypass);noiseMix=target.noise_enabled?(target.noise_auto_enabled?adaptiveNoise.strength():target.noise_mix):0;deesserMix=float(target.deesser_enabled);lastVolume=amp(target.output_db);initial=false;}}
    void block(const float* input,float* output) {
        // Parameter interpolation takes place on the audio thread; no callbacks into managed code.
        auto approach=[](float& a,float b){a+=(b-a)*.18126925f;};
        approach(current.highpass_hz,target.highpass_hz);approach(current.noise_mix,target.noise_mix);approach(current.output_db,target.output_db);
        approach(current.compressor_threshold_db,target.compressor_threshold_db);approach(current.compressor_ratio,target.compressor_ratio);
        hp.set(3,current.highpass_hz,0,.707f);
        for(int j=0;j<4;++j){approach(current.bands[j].frequency,target.bands[j].frequency);approach(current.bands[j].gain_db,target.bands[j].gain_db);approach(current.bands[j].q,target.bands[j].q);current.bands[j].type=target.bands[j].type;eq[j].set(current.bands[j].type,current.bands[j].frequency,current.bands[j].gain_db,current.bands[j].q);}
        double inputSum=0;
        std::array<float,SES_BLOCK> nextDry{},nextFiltered{};
        for(unsigned i=0;i<SES_BLOCK;++i){float x=clean(input[i]);nextDry[i]=x;nextFiltered[i]=hp.tick(x);scaled[i]=nextFiltered[i]*32768.f;inputSum+=x*x;if(std::abs(x)>=.995f)++meters.clipped_samples;}
        // Keep inference history warm so feature switches can crossfade without stale audio.
        float vad=rnnoise_process_frame(noise,wet.data(),scaled.data());
        float inputRms=std::sqrt(inputSum/SES_BLOCK);meters.input_db=db(inputRms);meters.speech_probability=vad;
        const float alignedLevel=inputLevels[0];
        // Level decisions must cover the emitted frame and the existing lookahead.
        // Returned RNNoise VAD already follows the delayed model spectrum; do not
        // add another two-frame delay to it.
        const float sensitivityLevel=std::max({alignedLevel,inputLevels[1],meters.input_db});
        meters.noise_floor_db=adaptiveNoise.observe(alignedLevel,vad);
        sensitivity.configure(target.sensitivity_mode,target.sensitivity_attack_ms,target.sensitivity_hold_ms,target.sensitivity_release_ms,target.sensitivity_hysteresis_db,target.sensitivity_ratio,target.sensitivity_max_reduction_db);
        sensitivity.observe(target.sensitivity_enabled,target.sensitivity_auto_enabled,target.sensitivity_threshold_db,meters.noise_floor_db,sensitivityLevel,vad,target.noise_enabled!=0);
        bool speech=alignedLevel>target.noise_floor_db+6 && (vad>=target.speech_threshold || (!target.noise_enabled && alignedLevel>target.noise_floor_db+16));
        float wanted=target.agc_enabled?gain:0;
        double speechSum=0;for(unsigned i=0;i<SES_BLOCK;++i){double x=filtered[i]*(1-noiseMix)+wet[i]*(noiseMix/32768.f);speechSum+=x*x;}
        if(target.agc_enabled && speech)wanted=std::clamp(target.target_db-db(float(std::sqrt(speechSum/SES_BLOCK))),target.min_gain_db,target.max_gain_db);
        gain+=(wanted-gain)*(wanted<gain?.0487706f:.00995017f);
        double outputSum=0;float minimumComp=0;
        float attack=std::exp(-1.f/(SES_RATE*target.attack_ms*.001f)),release=std::exp(-1.f/(SES_RATE*target.release_ms*.001f));
        const float ceiling=0.8912509381f,volume=amp(gain+current.output_db);
        const float wantedMix=target.noise_enabled?(target.noise_auto_enabled?adaptiveNoise.strength():current.noise_mix):0,volumeStep=(volume-lastVolume)/SES_BLOCK;
        for(unsigned i=0;i<SES_BLOCK;++i) {
            const float mixStep=target.noise_enabled&&target.noise_auto_enabled?1.f/48000.f:1.f/2400.f;
            noiseMix+=std::clamp(wantedMix-noiseMix,-mixStep,mixStep);deesserMix+=std::clamp(float(target.deesser_enabled)-deesserMix,-1.f/2400.f,1.f/2400.f);
            float x=filtered[i]*(1-noiseMix)+wet[i]*(noiseMix/32768.f);
            lastVolume+=volumeStep;x*=lastVolume;for(auto& b:eq)x=b.tick(x);
            float high=ess.tick(x);essEnvelope=.995f*essEnvelope+.005f*std::abs(high);
            {float reduction=std::clamp((db(essEnvelope)+35.f)*.5f,0.f,target.deesser_max_db);x-=high*(1-amp(-reduction))*deesserMix;}
            float absx=std::abs(x),time=absx>compEnvelope?attack:release;compEnvelope=time*compEnvelope+(1-time)*absx;
            float delta=db(compEnvelope)-current.compressor_threshold_db,knee=target.knee_db,wantedComp=0;
            if(delta>knee*.5f)wantedComp=(1/current.compressor_ratio-1)*delta;
            else if(knee>0 && delta>-knee*.5f)wantedComp=(1/current.compressor_ratio-1)*std::pow(delta+knee*.5f,2)/(2*knee);
            float ct=wantedComp<compGain?attack:release;compGain=ct*compGain+(1-ct)*wantedComp;x*=amp(compGain);minimumComp=std::min(minimumComp,compGain);
            float direction=float(target.bypass)-bypassMix;bypassMix+=std::clamp(direction,-1.f/2400.f,1.f/2400.f);
            float sensitivityGain=sensitivity.tick();
            x=x*sensitivityGain*(1-bypassMix)+dry[i]*bypassMix;
            float needed=std::abs(x)>ceiling?ceiling/std::abs(x):1.f;
            limitGain=needed<limitGain?needed:std::min(1.f,limitGain+.00035f);
            x=std::clamp(clean(x)*limitGain,-ceiling,ceiling);
            output[i]=target.muted?0.f:x;outputSum+=output[i]*output[i];
        }
        meters.noise_mix=target.bypass?0.f:noiseMix;
        meters.sensitivity_threshold_db=sensitivity.appliedThreshold();meters.sensitivity_gain=target.bypass?1.f:sensitivity.appliedGain();
        // RNNoise v0.2 synthesizes delayed_X: two 480-sample frames of algorithmic delay.
        dry=dryNext;filtered=filteredNext;dryNext=nextDry;filteredNext=nextFiltered;lastVolume=volume;
        inputLevels[0]=inputLevels[1];inputLevels[1]=meters.input_db;
        meters.output_db=db(float(std::sqrt(outputSum/SES_BLOCK)));meters.gain_db=gain;meters.compression_db=-minimumComp;meters.processed_frames+=SES_BLOCK;
    }
};
}
