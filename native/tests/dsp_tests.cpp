#include "ses.h"
#include "../src/clock.hpp"
#include "../src/adaptive_noise.hpp"
#include "../src/sensitivity.hpp"
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
    ses::Sensitivity detector;
    detector.observe(true,false,-50,-65,-60,0);
    for(int i=0;i<480;i++)detector.tick();
    check(detector.appliedGain()==0,"manual sensitivity initially rejects quiet sound");
    detector.observe(true,false,-50,-65,-40,0);
    for(int i=0;i<480;i++)detector.tick();
    check(detector.appliedGain()>.99f,"manual sensitivity opens for sound above threshold");
    for(int b=0;b<25;b++){detector.observe(true,false,-50,-65,-80,0);for(int i=0;i<480;i++)detector.tick();}
    check(detector.appliedGain()>.99f,"sensitivity holds short pauses and speech tails");
    for(int b=0;b<180;b++){detector.observe(true,false,-50,-65,-80,0);for(int i=0;i<480;i++)detector.tick();}
    check(detector.appliedGain()==0,"sensitivity closes smoothly during sustained quiet");
    detector.reset();detector.observe(true,true,-50,-65,-58,.8f);for(int i=0;i<480;i++)detector.tick();
    check(detector.appliedGain()>.99f,"automatic sensitivity protects detected soft speech below threshold");
    float oldThreshold=detector.appliedThreshold();detector.observe(true,true,-50,-40,-70,0);
    check(detector.appliedThreshold()-oldThreshold<=.02001f,"automatic sensitivity threshold ramps at most 2dB per second");
    detector.observe(true,false,-42,-65,-80,0);check(detector.appliedThreshold()==-42,"manual threshold restored after automatic mode");
    detector.reset();detector.observe(false,true,-50,-65,-100,0);for(int i=0;i<480;i++)detector.tick();check(detector.appliedGain()==1,"disabled sensitivity preserves audio exactly");
    auto tickBlock=[](ses::Sensitivity& d){for(unsigned i=0;i<SES_BLOCK;++i)d.tick();};
    detector.reset();detector.configure(0,10,0,10,0,2,24);detector.observe(true,false,-50,-65,-80,0);
    detector.observe(true,false,-50,-65,-40,0);tickBlock(detector);
    check(std::abs(detector.appliedGain()-.63212056f)<.0001f,"configured attack is a 10 ms time constant");
    for(unsigned i=0;i<30;++i)tickBlock(detector);detector.observe(true,false,-50,-65,-80,0);tickBlock(detector);
    check(std::abs(detector.appliedGain()-.36787944f)<.0001f,"configured release is a 10 ms time constant and zero hold closes immediately");
    detector.reset();detector.configure(0,.1f,50,5,6,2,24);detector.observe(true,false,-50,-65,-40,0);tickBlock(detector);
    for(unsigned i=0;i<5;++i){detector.observe(true,false,-50,-65,-80,0);tickBlock(detector);}
    check(detector.appliedGain()>.999f,"configured 50 ms hold retains five quiet blocks");
    detector.observe(true,false,-50,-65,-80,0);tickBlock(detector);
    check(detector.appliedGain()<.14f,"gate closes on the first block after configured hold");
    detector.reset();detector.configure(0,.1f,0,5,12,2,24);detector.observe(true,false,-50,-65,-40,0);tickBlock(detector);
    detector.observe(true,false,-50,-65,-60,0);tickBlock(detector);check(detector.appliedGain()>.999f,"configured hysteresis keeps near-threshold tails open");
    detector.observe(true,false,-50,-65,-63,0);tickBlock(detector);check(detector.appliedGain()<.14f,"configured hysteresis closes below its boundary");
    ses::Sensitivity expansion;expansion.configure(1,2,0,120,0,2,24);
    expansion.observe(true,false,-50,-65,-60,0);check(std::abs(expansion.appliedGain()-std::pow(10.f,-7.f/20))<.0001f,"soft expander knee applies expected below-threshold reduction");
    float quieterGain=expansion.appliedGain();expansion.observe(true,false,-50,-65,-70,0);for(unsigned i=0;i<SES_RATE*2;++i)expansion.tick();
    check(expansion.appliedGain()<quieterGain&&expansion.appliedGain()>0,"expander smoothly attenuates quieter sound without hard muting");
    expansion.observe(true,false,-50,-65,-120,0);for(unsigned i=0;i<SES_RATE*2;++i)expansion.tick();
    check(std::abs(expansion.appliedGain()-std::pow(10.f,-24.f/20))<.0001f,"expander reduction is capped at configured maximum");
    float previousExpansion=expansion.appliedGain();expansion.observe(true,false,-50,-65,-40,0);float firstExpansion=expansion.tick();
    check(firstExpansion>previousExpansion&&firstExpansion-previousExpansion<.011f,"expander speech reopening is sample-smoothed");tickBlock(expansion);
    check(expansion.appliedGain()>.99f,"expander opens quickly for speech");
    for(float ratio:{1.f,8.f})for(float maximum:{0.f,60.f}){
        expansion.reset();expansion.configure(1,.1f,0,5,0,ratio,maximum);expansion.observe(true,false,-50,-65,-120,0);
        check(expansion.appliedGain()<=1&&expansion.appliedGain()>=.000999f,"expander boundary configurations never boost or exceed maximum reduction");
        if(ratio==1||maximum==0)check(expansion.appliedGain()==1,"unity ratio or zero reduction preserves gain");
    }
    expansion.reset();float nan=std::numeric_limits<float>::quiet_NaN();expansion.configure(1,nan,nan,nan,nan,nan,nan);expansion.observe(true,true,nan,nan,nan,nan);tickBlock(expansion);
    check(std::isfinite(expansion.appliedGain())&&std::isfinite(expansion.appliedThreshold()),"invalid sensitivity observations and direct configuration cannot poison state");
    ses::Sensitivity voiceExpansion;voiceExpansion.configure(1,2,150,120,6,2,30);
    voiceExpansion.observe(true,true,-50,-65,-20,0,true);tickBlock(voiceExpansion);
    check(std::abs(voiceExpansion.appliedGain()-std::pow(10.f,-30.f/20))<.0001f,"automatic voice expander attenuates loud non-speech at startup");
    voiceExpansion.observe(true,true,-50,-65,-58,.8f,true);tickBlock(voiceExpansion);
    check(voiceExpansion.appliedGain()>.99f,"automatic voice expander opens for soft detected speech below level threshold");
    for(unsigned b=0;b<15;++b){voiceExpansion.observe(true,true,-50,-65,-20,0,true);tickBlock(voiceExpansion);}
    check(voiceExpansion.appliedGain()>.99f,"automatic voice expander preserves configured speech hangover");
    for(unsigned b=0;b<200;++b){voiceExpansion.observe(true,true,-50,-65,-20,0,true);tickBlock(voiceExpansion);}
    check(std::abs(voiceExpansion.appliedGain()-std::pow(10.f,-30.f/20))<.0001f,"loud non-speech cannot renew speech hold indefinitely");
    for(float ratio:{1.f,2.f})for(float maximum:{0.f,6.f,30.f}){
        voiceExpansion.reset();voiceExpansion.configure(1,2,0,120,6,ratio,maximum);
        voiceExpansion.observe(true,true,-50,-65,-20,0,true);tickBlock(voiceExpansion);
        check(voiceExpansion.appliedGain()>=std::pow(10.f,-maximum/20)-.00001f&&voiceExpansion.appliedGain()<=1,"voice expansion respects configured attenuation cap");
        if(ratio==1||maximum==0)check(voiceExpansion.appliedGain()==1,"voice expansion preserves explicit unity settings");
    }
    voiceExpansion.reset();voiceExpansion.configure(1,2,0,120,6,2,30);
    voiceExpansion.observe(true,false,-50,-65,-20,0,true);tickBlock(voiceExpansion);
    check(voiceExpansion.appliedGain()>.99f,"manual expander stays level controlled even with RNNoise");
    voiceExpansion.reset();voiceExpansion.observe(true,true,-50,-65,-20,0,false);tickBlock(voiceExpansion);
    check(voiceExpansion.appliedGain()>.99f,"noise-disabled automatic expander stays level controlled");
    voiceExpansion.reset();voiceExpansion.observe(false,true,-50,-65,-20,0,true);tickBlock(voiceExpansion);
    check(voiceExpansion.appliedGain()==1,"disabled voice expansion preserves unity");
    SesDspConfig c{}; ses_default_config(&c); check(ses_abi_version()==SES_ABI_VERSION,"ABI version"); check(ses_config_size()==sizeof(c),"config layout");
    check(sizeof(c)==192&&ses_metrics_size()==sizeof(SesMetrics),"ABI 5 config appends fields while metrics layout remains stable");
    check(c.sensitivity_mode==0&&c.sensitivity_attack_ms==2&&c.sensitivity_hold_ms==300&&c.sensitivity_release_ms==120&&c.sensitivity_hysteresis_db==6&&c.sensitivity_ratio==2&&c.sensitivity_max_reduction_db==24,"native defaults preserve gate behavior");
    for(auto member:{&SesDspConfig::sensitivity_attack_ms,&SesDspConfig::sensitivity_hold_ms,&SesDspConfig::sensitivity_release_ms,&SesDspConfig::sensitivity_hysteresis_db,&SesDspConfig::sensitivity_ratio,&SesDspConfig::sensitivity_max_reduction_db}){
        auto bad=c;bad.*member=nan;check(ses_validate_config(&bad)!=0,"reject every NaN sensitivity parameter");
        bad=c;bad.*member=std::numeric_limits<float>::infinity();check(ses_validate_config(&bad)!=0,"reject every infinite sensitivity parameter");
        bad=c;bad.*member=-1;check(ses_validate_config(&bad)!=0,"reject every below-minimum sensitivity parameter");
        bad=c;bad.*member=2001;check(ses_validate_config(&bad)!=0,"reject every above-maximum sensitivity parameter");
    }
    auto boundary=c;boundary.sensitivity_attack_ms=.1f;boundary.sensitivity_hold_ms=0;boundary.sensitivity_release_ms=5;boundary.sensitivity_hysteresis_db=0;boundary.sensitivity_ratio=1;boundary.sensitivity_max_reduction_db=0;check(ses_validate_config(&boundary)==0,"accept lower sensitivity range endpoints");
    boundary.sensitivity_attack_ms=100;boundary.sensitivity_hold_ms=2000;boundary.sensitivity_release_ms=2000;boundary.sensitivity_hysteresis_db=24;boundary.sensitivity_ratio=8;boundary.sensitivity_max_reduction_db=60;check(ses_validate_config(&boundary)==0,"accept upper sensitivity range endpoints");
    boundary=c;boundary.sensitivity_mode=2;check(ses_validate_config(&boundary)!=0,"reject invalid expander mode");
    c.noise_enabled=0; c.agc_enabled=0; c.highpass_hz=20; c.compressor_ratio=1;
    c.sensitivity_enabled=1;c.sensitivity_auto_enabled=0;c.sensitivity_threshold_db=-50;
    auto gatedQuiet=process(tone(.001f,3),c);check(rms(gatedQuiet,SES_RATE*2)==0,"real audio below manual threshold is not transmitted");
    auto gatedVoice=process(tone(.1f,3),c);check(rms(gatedVoice,SES_RATE*2)>.06f,"real audio above threshold passes");
    c.sensitivity_mode=1;auto expandedQuiet=process(tone(.001f,3),c);
    check(rms(expandedQuiet,SES_RATE*2)>0&&rms(expandedQuiet,SES_RATE*2)<.0003f,"real below-threshold audio is gently attenuated by expander");
    check(rms(process(tone(.1f,3),c),SES_RATE*2)>.06f,"expander passes above-threshold voice");
    check(peak(process(std::vector<float>(SES_RATE*2),c))==0,"expander never boosts silence");c.sensitivity_mode=0;
    c.bypass=1;check(rms(process(tone(.001f,2),c),SES_RATE)>.0006f,"bypass skips sensitivity");
    c.muted=1;check(peak(process(tone(.1f),c))==0,"sensitivity bypass still honors mute");c.muted=0;c.bypass=0;
    auto* talk=ses_create();auto talkConfig=c;talkConfig.bypass=1;ses_update(talk,&talkConfig);auto talkInput=tone(.1f,1);std::vector<float> talkOutput(talkInput.size());
    check(ses_set_talk_gate(talk,1,0)==0,"PTT gate accepts released state");ses_process(talk,talkInput.data(),talkOutput.data(),uint32_t(talkInput.size()));check(peak(talkOutput)==0,"released PTT mutes bypassed audio");
    SesMetrics talkMetrics{};ses_read_metrics(talk,&talkMetrics);check(talkMetrics.output_db==-120,"talk gate meter reflects muted output");
    ses_set_talk_gate(talk,1,1);ses_process(talk,talkInput.data(),talkOutput.data(),uint32_t(talkInput.size()));check(peak(talkOutput)>.09f,"held PTT opens bypassed audio");
    talkConfig.muted=1;ses_update(talk,&talkConfig);ses_process(talk,talkInput.data(),talkOutput.data(),uint32_t(talkInput.size()));check(peak(talkOutput)==0,"manual mute overrides held PTT");
    talkConfig.muted=0;ses_update(talk,&talkConfig);ses_set_talk_gate(talk,2,1);ses_process(talk,talkInput.data(),talkOutput.data(),uint32_t(talkInput.size()));check(peak(talkOutput)==0,"held hold-to-mute silences bypassed audio");
    ses_set_talk_gate(talk,2,0);ses_process(talk,talkInput.data(),talkOutput.data(),uint32_t(talkInput.size()));check(peak(talkOutput)>.09f,"released hold-to-mute opens audio");
    ses_set_talk_gate(talk,1,0);ses_update(talk,&talkConfig);ses_process(talk,talkInput.data(),talkOutput.data(),uint32_t(talkInput.size()));check(peak(talkOutput)==0,"full config update preserves independent talk gate");
    check(ses_set_talk_gate(talk,3,0)!=0&&ses_set_talk_gate(talk,0,2)!=0&&ses_set_talk_gate(nullptr,0,0)!=0,"invalid talk gate requests rejected");
    ses_set_talk_gate(talk,0,0);ses_process(talk,talkInput.data(),talkOutput.data(),uint32_t(talkInput.size()));check(peak(talkOutput)>.09f,"disabled talk gate restores audio");ses_destroy(talk);
    auto word=tone(.1f,2);std::fill(word.begin(),word.begin()+SES_RATE,0);auto gatedWord=process(word,c);c.sensitivity_enabled=0;auto plainWord=process(word,c);
    double gateStart=0,plainStart=0;for(unsigned i=SES_RATE+960;i<SES_RATE+1440;++i){gateStart+=gatedWord[i]*gatedWord[i];plainStart+=plainWord[i]*plainWord[i];}
    check(gateStart>plainStart*.98,"existing lookahead preserves word onset above threshold");
    // The shortest configurable hold must preserve the delayed audio, too.
    c.sensitivity_enabled=1;c.sensitivity_hold_ms=0;c.sensitivity_release_ms=5;
    auto shortWord=tone(.1f,2);std::fill(shortWord.begin(),shortWord.end(),0);
    for(unsigned i=SES_RATE;i<SES_RATE+SES_BLOCK;++i)shortWord[i]=.1f*std::sin(6.28318530718*997*i/SES_RATE);
    auto shortGated=process(shortWord,c);c.sensitivity_enabled=0;auto shortPlain=process(shortWord,c);
    double shortGateEnergy=0,shortPlainEnergy=0;
    for(unsigned i=SES_RATE+960;i<SES_RATE+960+SES_BLOCK;++i){shortGateEnergy+=shortGated[i]*shortGated[i];shortPlainEnergy+=shortPlain[i]*shortPlain[i];}
    check(shortGateEnergy>shortPlainEnergy*.98,"zero hold preserves a short word throughout the existing audio delay");
    auto* onsetGain=ses_create();auto gainConfig=c;gainConfig.agc_enabled=1;gainConfig.noise_enabled=0;
    ses_update(onsetGain,&gainConfig);std::vector<float> onsetSilence(SES_RATE),onsetOutput(SES_RATE);
    ses_process(onsetGain,onsetSilence.data(),onsetOutput.data(),SES_RATE);
    std::vector<float> onsetBlock(SES_BLOCK,.1f),onsetResult(SES_BLOCK);SesMetrics onsetMeters{};
    for(unsigned i=0;i<2;++i){ses_process(onsetGain,onsetBlock.data(),onsetResult.data(),SES_BLOCK);ses_read_metrics(onsetGain,&onsetMeters);check(std::abs(onsetMeters.gain_db)<.0001f,"AGC does not amplify delayed silence before speech arrives");}
    ses_destroy(onsetGain);c.sensitivity_hold_ms=300;c.sensitivity_release_ms=120;
    auto badSensitivity=c;badSensitivity.sensitivity_threshold_db=-91;check(ses_validate_config(&badSensitivity)!=0,"reject out of range sensitivity threshold");
    badSensitivity=c;badSensitivity.sensitivity_auto_enabled=2;check(ses_validate_config(&badSensitivity)!=0,"reject invalid sensitivity mode flag");
    auto loud=tone(4); auto limited=process(loud,c); check(peak(limited)<=0.891252f,"limiter ceiling even overloaded input");
    c.bypass=1; auto by=process(loud,c); check(peak(by)<=0.891252f,"bypass preserves limiter");
    c.muted=1; check(peak(process(tone(0.4),c))==0,"mute survives bypass"); c.muted=0; c.bypass=0;
    auto invalid=tone(0.1); invalid[100]=std::numeric_limits<float>::infinity(); invalid[101]=std::numeric_limits<float>::quiet_NaN();
    auto finite=process(invalid,c); check(std::all_of(finite.begin(),finite.end(),[](float x){return std::isfinite(x);}),"invalid input cannot contaminate output");
    auto invalidConfig=c; invalidConfig.bands[0].frequency=std::numeric_limits<float>::quiet_NaN(); check(ses_validate_config(&invalidConfig)!=0,"reject NaN settings");
    invalidConfig=c; invalidConfig.compressor_ratio=0; check(ses_validate_config(&invalidConfig)!=0,"reject zero compressor ratio");
    invalidConfig=c; invalidConfig.version=999; check(ses_validate_config(&invalidConfig)!=0,"reject incompatible ABI");
    ses::AdaptiveNoise estimator;estimator.reset(-65);
    for(unsigned i=0;i<300;++i)estimator.observe(-18,.9f);
    check(std::abs(estimator.observe(-18,.9f)+65)<.001f,"speech is excluded from ambient estimate");
    for(unsigned i=0;i<20;++i)estimator.observe(-30,0);
    check(std::abs(estimator.observe(-30,0)+65)<.001f,"speech hangover protects sentence endings");
    check(std::isfinite(estimator.observe(std::numeric_limits<float>::quiet_NaN(),0)),"invalid ambient observations are ignored");
    auto* e=ses_create(); c.agc_enabled=1; c.noise_floor_db=-65; check(ses_update(e,&c)==0,"AGC config");
    std::vector<float> silence(SES_RATE*6),out(silence.size()); ses_process(e,silence.data(),out.data(),static_cast<uint32_t>(silence.size()));
    SesMetrics m{}; ses_read_metrics(e,&m); check(std::abs(m.gain_db)<0.01f,"AGC does not grow during silence"); check(peak(out)==0,"silence remains silence"); ses_destroy(e);
    // Automatic strength must respond to a sustained noise change without a UI timer.
    auto* automatic=ses_create();ses_default_config(&c);c.agc_enabled=0;c.noise_auto_enabled=1;
    check(ses_update(automatic,&c)==0,"automatic noise config accepted");
    std::vector<float> adaptiveInput(SES_RATE*6),adaptiveOutput(adaptiveInput.size());uint32_t adaptiveSeed=91;
    for(auto& x:adaptiveInput){adaptiveSeed=1664525*adaptiveSeed+1013904223;x=(float(adaptiveSeed)/4294967295.f-.5f)*.001f;}
    ses_process(automatic,adaptiveInput.data(),adaptiveOutput.data(),uint32_t(adaptiveInput.size()));ses_read_metrics(automatic,&m);float quietMix=m.noise_mix;
    for(auto& x:adaptiveInput){adaptiveSeed=1664525*adaptiveSeed+1013904223;x=(float(adaptiveSeed)/4294967295.f-.5f)*.15f;}
    ses_process(automatic,adaptiveInput.data(),adaptiveOutput.data(),uint32_t(adaptiveInput.size()));ses_read_metrics(automatic,&m);
    check(m.noise_mix>quietMix+.15f,"automatic strength increases in a noisier room");
    check(m.noise_mix<=.98f&&m.noise_mix>=.35f,"automatic strength remains bounded");
    c.noise_auto_enabled=0;c.noise_mix=.27f;ses_update(automatic,&c);ses_process(automatic,adaptiveInput.data(),adaptiveOutput.data(),uint32_t(adaptiveInput.size()));ses_read_metrics(automatic,&m);
    check(std::abs(m.noise_mix-.27f)<.001f,"manual strength survives automatic mode");
    c.noise_enabled=0;c.noise_auto_enabled=1;ses_update(automatic,&c);ses_process(automatic,adaptiveInput.data(),adaptiveOutput.data(),48000);ses_read_metrics(automatic,&m);
    check(m.noise_mix==0,"noise disabled overrides automatic mode");ses_destroy(automatic);
    invalidConfig=c;invalidConfig.noise_auto_enabled=2;check(ses_validate_config(&invalidConfig)!=0,"reject invalid automatic flag");
    c.agc_enabled=0;c.noise_auto_enabled=0; c.compressor_ratio=4; c.compressor_threshold_db=-24;
    auto compressed=process(tone(0.7,4),c); check(rms(compressed,SES_RATE*3)<0.15f,"compressor reduces sustained loud speech");
    c.compressor_ratio=1; c.highpass_hz=100; auto low=process(tone(0.2,2,20),c); auto mid=process(tone(0.2,2,1000),c);
    check(rms(low,SES_RATE)<rms(mid,SES_RATE)*0.1f,"highpass removes low rumble");
    c.highpass_hz=20; c.noise_enabled=1; c.noise_mix=1;
    std::vector<float> noise(SES_RATE*3); uint32_t seed=42; for(auto& x:noise){seed=1664525*seed+1013904223; x=(static_cast<float>(seed)/4294967295.f-0.5f)*0.02f;}
    auto cleaned=process(noise,c); check(rms(cleaned,SES_RATE*2)<rms(noise,SES_RATE*2)*0.8f,"RNNoise suppresses stationary noise");
    // Exercise the new branch through real RNNoise and the exported DSP API.
    auto voiceConfig=c;voiceConfig.sensitivity_enabled=1;voiceConfig.sensitivity_mode=1;
    voiceConfig.sensitivity_auto_enabled=0;voiceConfig.sensitivity_hold_ms=150;
    voiceConfig.sensitivity_max_reduction_db=30;voiceConfig.noise_mix=1;
    auto levelNoise=process(noise,voiceConfig);voiceConfig.sensitivity_auto_enabled=1;
    auto voiceNoise=process(noise,voiceConfig);
    check(rms(voiceNoise,SES_RATE*2)<rms(levelNoise,SES_RATE*2)*.3f,"RNNoise automatic soft expansion reduces non-speech versus level-only control");
    std::vector<float> softProxy(SES_RATE*3);
    for(size_t i=SES_RATE;i<SES_RATE*2;++i){
        float local=float(i-SES_RATE)/SES_RATE;
        float envelope=std::min(1.f,local/.014f)*std::min(1.f,(1.f-local)/.07f);
        for(unsigned harmonic=1;harmonic<20;++harmonic)
            softProxy[i]+=.008f*envelope*std::sin(6.28318530718*116*harmonic*i/SES_RATE)/harmonic;
    }
    auto autoProxy=process(softProxy,voiceConfig);voiceConfig.sensitivity_auto_enabled=0;
    auto levelProxy=process(softProxy,voiceConfig);
    double autoOnset=0,levelOnset=0;
    for(unsigned i=SES_RATE+960;i<SES_RATE+1920;++i){autoOnset+=autoProxy[i]*autoProxy[i];levelOnset+=levelProxy[i]*levelProxy[i];}
    check(levelOnset>0&&autoOnset>levelOnset*.79,"speech-aware real RNNoise retains soft voiced proxy onset within 1 dB of level control");
    // Keyboard-like synthetic broadband clicks, not a real keyboard/speech recording.
    std::vector<float> keyboard(SES_RATE*4);seed=83;
    for(size_t i=0;i<keyboard.size();++i){seed=1664525*seed+1013904223;float n=float(seed)/4294967295.f-.5f;
        unsigned offset=unsigned(i%(SES_RATE/8));keyboard[i]=n*.0005f;
        if(i>SES_RATE&&offset<480)keyboard[i]+=n*.08f*std::exp(-float(offset)/90.f);}
    c.agc_enabled=0;c.sensitivity_enabled=0;c.compressor_ratio=1;c.noise_mix=.65f;
    auto mixedKeys=process(keyboard,c);c.noise_mix=1;auto cleanKeys=process(keyboard,c);
    std::printf("keyboard fixture mixed RMS %.8f, full-wet RMS %.8f\n",rms(mixedKeys,SES_RATE),rms(cleanKeys,SES_RATE));
    check(rms(cleanKeys,SES_RATE)<rms(mixedKeys,SES_RATE)*.6f,"full wet reduces keyboard-like bursts more than 35 percent dry leak");
    check(peak(cleanKeys)<=.891252f,"full wet keyboard fixture remains finite and limited");
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
    transition=ses_create();c.noise_enabled=0;c.output_db=0;ses_update(transition,&c);previous=0;jump=0;
    for(unsigned b=0;b<250;++b){for(unsigned i=0;i<480;++i)block[i]=.1f*std::sin(6.28318530718*173.3*(b*480+i)/SES_RATE);if(b==200){c.output_db=12;ses_update(transition,&c);}ses_process(transition,block.data(),result.data(),480);if(b>=200&&b<=210){jump=std::max(jump,std::abs(result[0]-previous));for(unsigned i=1;i<480;++i)jump=std::max(jump,std::abs(result[i]-result[i-1]));}previous=result.back();}
    check(jump<.015,"output gain ramps at sample rate without clicks");ses_destroy(transition);
    auto* fuzz=ses_create();uint32_t random=1337;bool bounded=true;
    for(unsigned trial=0;trial<300;++trial){ses_default_config(&c);c.noise_enabled=trial%2;c.noise_auto_enabled=trial%3==0;c.agc_enabled=trial%3!=0;c.sensitivity_enabled=trial%2;c.sensitivity_auto_enabled=trial%3==0;c.sensitivity_threshold_db=-90+float(trial%81);c.output_db=12;for(auto& band:c.bands){random=1664525*random+1013904223;band.frequency=20+(random%19981);band.gain_db=float(int(random%25)-12);band.q=.2f+float(random%980)/100;}ses_update(fuzz,&c);for(auto& x:block){random=1664525*random+1013904223;x=float(int(random%1000)-500)/50;}ses_process(fuzz,block.data(),result.data(),480);for(auto x:result)if(!std::isfinite(x)||std::abs(x)>.891252f)bounded=false;}
    check(bounded,"adversarial legal filters and overloaded samples remain finite and bounded");ses_destroy(fuzz);
    auto* empty=ses_create(); float dest[8]{}; check(ses_copy_sample(empty,0,dest,8)==0,"no audio recorded implicitly"); check(ses_begin_sample(empty,21)!=0,"sample limit enforced"); ses_destroy(empty);
    if(argc>1 && std::string_view(argv[1])=="--benchmark") {
        auto* b=ses_create(); ses_default_config(&c); ses_update(b,&c); auto x=tone(0.15,60,220); std::vector<float> y(x.size());
        auto begin=std::chrono::steady_clock::now(); ses_process(b,x.data(),y.data(),static_cast<uint32_t>(x.size())); auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
        std::printf("BENCHMARK audio_seconds=60 wall_ms=%.2f one_core_realtime_percent=%.2f\n",ms,ms/600); ses_destroy(b);
    }
    std::printf("%d checks, %d failures\n",checks,failures); return failures?1:0;
}
