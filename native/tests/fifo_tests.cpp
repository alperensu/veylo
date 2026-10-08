#include "../src/audio_fifo.hpp"
#include "ses.h"
#include <cstdio>
#include <thread>
#include <limits>

static unsigned checks=0,failures=0;
static void check(bool pass,const char* name){++checks;if(!pass){++failures;std::printf("FAIL %s\n",name);}}
int main(){
    std::array<float,480> block;block.fill(.25f);std::array<float,1440> output{};
    ses::AudioFifo fifo;
    auto empty=fifo.read(output.data(),480,960);check(empty.waiting&&!empty.underrun&&empty.rendered==0,"empty FIFO waits and emits silence");
    check(fifo.write(block.data(),480)&&fifo.write(block.data(),480),"two producer blocks fit");
    auto first=fifo.read(output.data(),480,960);check(first.rendered==480&&!first.underrun,"primed stream renders full callback");
    check(output[0]==0&&std::all_of(output.begin()+1,output.begin()+480,[](float x){return x==.25f;}),"causal interpolation preserves constant after one sample alignment");
    auto starve=fifo.read(output.data(),1440,960);check(starve.underrun&&starve.underflowRemaining>0,"starvation diagnosed once per callback");
    check(std::all_of(output.begin()+starve.rendered,output.end(),[](float x){return x==0;}),"starvation remainder is silent, no replay");
    fifo.reset();for(unsigned i=0;i<17;++i)check(fifo.write(block.data(),480),"bounded blocks fill queue");
    check(!fifo.write(block.data(),480),"overflow refuses complete block");
    fifo.reset();check(fifo.read(output.data(),480,960).waiting,"reset discards old audio and clock state");
    // Real packet events: capture publishes only whole 480-sample DSP blocks.
    // Playback uses the same per-sample interpolation/atomic cursor code as WASAPI.
    for(double ppm:{-600.,600.})for(double phase:{0.,.1,5.,9.9}){
        fifo.reset();double capture=0,playback=phase,interval=10/(1+ppm/1e6);unsigned under=0,over=0,maxFill=0;bool finite=true;
        while(std::min(capture,playback)<3600000){
            if(capture<=playback){if(!fifo.write(block.data(),480))++over;capture+=interval;}
            else{auto result=fifo.read(output.data(),480,960);under+=result.underrun;maxFill=std::max(maxFill,result.remainingFill);finite=finite&&std::isfinite(result.ratio)&&std::abs(result.ratio-1)<=.001000001;playback+=10;}
        }
        std::printf("PACKET_HOUR ppm=%.0f phase_ms=%.1f underruns=%u overruns=%u max_remaining=%u\n",ppm,phase,under,over,maxFill);
        check(under==0&&over==0&&finite,"one-hour packet clock remains continuous at +/-600ppm");
        check(maxFill<=961,"packet model retains 20ms FIFO target plus one causal alignment sample");
    }
    // Smaller callbacks and non-integral DSP boundaries, with production interpolation.
    for(unsigned frames:{120u,240u,441u})for(double ppm:{-600.,600.}){
        fifo.reset();double capture=0,playback=.1,interval=10/(1+ppm/1e6);unsigned under=0,over=0;
        while(std::min(capture,playback)<60000){if(capture<=playback){if(!fifo.write(block.data(),480))++over;capture+=interval;}else{auto r=fifo.read(output.data(),frames,960);under+=r.underrun;playback+=frames/48.;}}
        check(under==0&&over==0,"arbitrary sub-block callbacks preserve packet clock continuity");
    }
    fifo.reset();fifo.write(block.data(),480);fifo.write(block.data(),480);
    auto large=fifo.read(output.data(),960,960);check(large.waiting&&large.rendered==0&&!large.underrun,"oversized initial callback waits for interpolation guard");
    fifo.write(block.data(),480);large=fifo.read(output.data(),960,960);check(!large.waiting&&!large.underrun&&large.rendered==960,"large callback renders after sufficient priming");
    // No capture between two callbacks. Compare a non-periodic waveform against
    // an independent causal interpolation oracle, including fractional clock ratios.
    std::array<float,16320> waveform{};
    for(unsigned i=0;i<waveform.size();++i)waveform[i]=.2f*float(std::sin(i*.173+i*i*.000003));
    fifo.reset();fifo.write(waveform.data(),480);fifo.write(waveform.data()+480,480);double position=0;bool matching=true;
    for(unsigned callback=0;callback<2;++callback){auto result=fifo.read(output.data(),480,960);check(!result.underrun&&result.rendered==480,"two render callbacks consume two real packets without future lookahead");
        for(unsigned i=0;i<480;++i){const auto index=unsigned(std::floor(position));const double part=position-index;const float previous=index?waveform[index-1]:0,current=waveform[index];matching=matching&&std::abs(output[i]-(previous+(current-previous)*part))<.00001;position+=result.ratio;}}
    check(matching,"packet-tail waveform matches real previous/current interpolation");
    auto missing=fifo.read(output.data(),480,960);check(missing.underrun&&missing.underflowAvailable==0&&missing.underflowRemaining>400,"true capture gap remains an underrun, never repeated tail audio");
    check(std::all_of(output.begin()+missing.rendered,output.begin()+480,[](float x){return x==0;}),"true capture gap remainder is silent");
    fifo.write(waveform.data()+960,480);fifo.write(waveform.data()+1440,480);auto resumed=fifo.read(output.data(),480,960);check(!resumed.underrun&&resumed.rendered==480&&output[0]==0,"reprime clears causal history after true capture gap");
    // Fill and refill across the ring boundary. Callback partitions differ from
    // the DSP block size and servo hits both endpoints of its bounded ratio.
    for(unsigned target:{960u,7680u}){
    fifo.reset();unsigned written=7680;fifo.write(waveform.data(),written);position=0;matching=true;bool continuous=true;double minRatio=2,maxRatio=0;
    for(unsigned callback=0;position<12000;++callback){unsigned frames=callback%3==0?240:callback%3==1?480:720;
        if(written-position<1800&&written+3840<=waveform.size()){continuous=continuous&&fifo.write(waveform.data()+written,3840);written+=3840;}
        auto result=fifo.read(output.data(),frames,target);continuous=continuous&&!result.underrun&&result.rendered==frames;minRatio=std::min(minRatio,result.ratio);maxRatio=std::max(maxRatio,result.ratio);
        for(unsigned i=0;i<result.rendered;++i){auto index=unsigned(std::floor(position));double part=position-index;const float previous=index?waveform[index-1]:0,current=waveform[index];matching=matching&&std::abs(output[i]-(previous+(current-previous)*part))<.00001;position+=result.ratio;}}
    check(continuous&&matching&&(target==960?maxRatio>=1.001:minRatio<=.999),"fractional interpolation stays continuous at both clock limits across partitions and ring wrap");
    }
    // Ordered scheduling delays do not change the underlying sample clocks.
    // Use the same callback-aware reserve policy as the WASAPI audio path.
    for(unsigned frames:{120u,240u,441u,480u,960u,1440u})for(double ppm:{-600.,0.,600.})for(unsigned mode=0;mode<4;++mode)for(double phase:{0.,.1,5.,9.9}){
        fifo.reset();unsigned ci=0,pi=0,under=0,over=0;double capture=0,playback=phase,interval=10/(1+ppm/1e6);bool bounded=true;
        auto captureDelay=[&](unsigned n){return mode?1.75*(1+std::sin(n*.019)):0.;};
        auto playbackDelay=[&](unsigned n){return mode>=2?(mode==2?1.75*(1+std::sin(n*.011)):(n%4096==1024?14.9:0.)):0.;};
        while(std::min(capture,playback)<60000){
            if(capture<=playback){over+=!fifo.write(block.data(),480);++ci;capture=ci*interval+captureDelay(ci);}
            else{auto result=fifo.readBuffered(output.data(),frames,960);under+=result.underrun;
                bounded=bounded&&std::isfinite(result.ratio)&&std::abs(result.ratio-1)<=.001000001;
                double previous=playback;++pi;playback=std::max(previous+.001,phase+pi*(frames/48.)+playbackDelay(pi));}
        }
        if(under||over)std::printf("JITTER frames=%u ppm=%.0f mode=%u under=%u over=%u\n",frames,ppm,mode,under,over);
        check(under==0&&over==0&&bounded,"callback-aware reserve handles ordered packet jitter and large periods");
    }
    // Validate the actual buffered consumer against the independent waveform
    // oracle, including fractional resampling across ring wrap and partitions.
    for(unsigned budget:{960u,2880u}){
        fifo.reset();unsigned written=5760;fifo.write(waveform.data(),written);position=0;matching=true;bool continuous=true;
        for(unsigned callback=0;position<12000;++callback){unsigned frames=callback%3==0?240:callback%3==1?480:720;
            if(written-position<1800&&written+3840<=waveform.size()){continuous=continuous&&fifo.write(waveform.data()+written,3840);written+=3840;}
            auto result=fifo.readBuffered(output.data(),frames,budget);continuous=continuous&&!result.underrun&&result.rendered==frames;
            for(unsigned i=0;i<result.rendered;++i){auto index=unsigned(std::floor(position));double part=position-index;
                const float previous=index?waveform[index-1]:0,current=waveform[index];
                matching=matching&&std::abs(output[i]-(previous+(current-previous)*part))<.00001;position+=result.ratio;}
        }
        check(continuous&&matching,"buffered waveform matches interpolation oracle through packet partitions and ring wrap");
    }
    fifo.reset();fifo.write(block.data(),480);fifo.write(block.data(),480);fifo.write(block.data(),480);
    auto buffered=fifo.readBuffered(output.data(),480,960);
    check(!buffered.waiting&&!buffered.underrun&&buffered.rendered==480,"buffered render starts after callback plus post-render reserve");
    // Genuine loss remains visible; reserve is not an audio replay fallback.
    unsigned actualMissing=0;for(unsigned i=0;i<12;++i)actualMissing+=fifo.readBuffered(output.data(),480,960).underrun;
    check(actualMissing==1,"buffered path reports true starvation once then waits for fresh data");
    check(std::all_of(output.begin(),output.begin()+480,[](float x){return x==0;}),"buffered path outputs silence after source loss");
    auto* engine=ses_create();SesStreamDiagnostics diagnostic{};static_assert(sizeof(SesStreamDiagnostics)==96);
    check(ses_read_stream_diagnostics(engine,1,sizeof(diagnostic),&diagnostic)==0&&diagnostic.version==1&&diagnostic.size==96,"diagnostic extension reads versioned layout");
    diagnostic.size=123;check(ses_read_stream_diagnostics(engine,2,sizeof(diagnostic),&diagnostic)==-2&&diagnostic.size==123,"unsupported diagnostic version leaves output untouched");
    check(ses_read_stream_diagnostics(engine,1,sizeof(diagnostic)-1,&diagnostic)==-2&&diagnostic.size==123,"short diagnostic layout rejected before write");
    check(ses_read_stream_diagnostics(nullptr,1,sizeof(diagnostic),&diagnostic)==-2&&ses_read_stream_diagnostics(engine,1,sizeof(diagnostic),nullptr)==-2,"null diagnostic inputs rejected");
    ses_destroy(engine);
    std::printf("%u checks, %u failures\n",checks,failures);return failures?1:0;
}
