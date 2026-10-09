#include "../../driver/shared/audio_validation.h"
#include "../../driver/shared/pcm_ring.h"
#include "../src/transfer_queue.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "../src/worker_timer.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <limits>
static unsigned checks=0;
static void check(bool ok,const char* name){++checks;if(!ok){std::fprintf(stderr,"FAIL %s\n",name);std::exit(1);}}
static void workerTimer(){
    ses::WorkerTimer timer;
    HANDLE stop=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    check(stop!=nullptr,"Create private worker stop event");
    check(timer.wait(stop,2)==WAIT_FAILED,"Uninitialized cadence fails closed");
    check(timer.open(),"Private high-resolution cadence timer opens");
    check(timer.wait(stop,0)==WAIT_FAILED,"Zero cadence is rejected");
    check(timer.wait(stop,2)==WAIT_OBJECT_0+1,"Private cadence wakes without stop");
    SetEvent(stop);
    check(timer.wait(stop,500)==WAIT_OBJECT_0,"Stop preempts a pending worker timer");
    timer.close();
    check(timer.wait(stop,2)==WAIT_FAILED,"Closed cadence fails rather than polling");
    check(timer.open(),"Cadence can reopen after stop");
    check(timer.wait(stop,2)==WAIT_OBJECT_0,"Reopened cadence retains stop precedence");
    CloseHandle(stop);
}
static void clockAndFormat(){
    using namespace ses_driver;
    for(uint32_t bits:{16u,32u}){
        PcmFormat f{104,0xfffe,1,48000,48000*bits/8,bits/8,bits,22};
        check(validCaptureFormat(f),"Extensible PCM16/32 accepted");
        auto bad=f;bad.average_bytes=0;check(!validCaptureFormat(bad),"Zero byte rate rejected before division");
        bad=f;bad.average_bytes=192001;check(!validCaptureFormat(bad),"Inconsistent byte rate rejected");
        bad=f;bad.block_align=0;check(!validCaptureFormat(bad),"Zero alignment rejected");
        bad=f;bad.block_align=3;check(!validCaptureFormat(bad),"Inconsistent alignment rejected");
        for(uint32_t bytes=0;bytes<104;++bytes){bad=f;bad.format_bytes=bytes;check(!validCaptureFormat(bad),"Truncated extensible format rejected");}
        for(uint32_t extra:{0u,21u,23u,65535u}){bad=f;bad.extra_bytes=extra;check(!validCaptureFormat(bad),"Oversized or inconsistent cbSize rejected");}
        bad=f;bad.format_bytes=0xffffffff;check(!validCaptureFormat(bad),"Unbounded FormatSize rejected");
        bad=f;bad.rate=44100;check(!validCaptureFormat(bad),"Wrong rate rejected");
        bad=f;bad.channels=2;check(!validCaptureFormat(bad),"Wrong channels rejected");
        bad=f;bad.bits=24;check(!validCaptureFormat(bad),"Unsupported bit depth rejected");
        f.tag=1;f.extra_bytes=0;f.format_bytes=82;check(validCaptureFormat(f),"Packed legacy PCM accepted");
        f.format_bytes=88;check(validCaptureFormat(f),"Aligned legacy PCM accepted");
        bad=f;bad.extra_bytes=65535;check(!validCaptureFormat(bad),"Legacy PCM cannot request extra copy bytes");
    }
    check(validNotificationBuffer(3840,2,4),"Aligned 10ms notifications accepted");
    check(!validNotificationBuffer(6,3,4),"Truncation cannot invalidate notification alignment");
    check(!validNotificationBuffer(4,1,4),"Sub-millisecond timer period rejected");
    check(!validNotificationBuffer(1920,3,4),"Fractional millisecond notifications rejected before timer rounding");
    check(!validNotificationBuffer(3840,0,4),"Zero notification count rejected");
    check(!validNotificationBuffer(3840,2,0),"Zero alignment rejected before modulo");
    auto movement=advancePcm(10000,4,0);check(movement.bytes==192&&movement.fraction==0,"Exactly 48 PCM32 frames per millisecond");
    uint32_t fraction=0;uint64_t bytes=0;
    for(uint64_t time:{3333u,3333u,3334u}){movement=advancePcm(time,4,fraction);bytes+=movement.bytes;fraction=movement.fraction;check(movement.bytes%4==0,"Every update stays frame aligned");}
    check(bytes==192&&fraction==0,"Fractional time is conserved across updates");
    check(advancePcm(300000000,4,0).bytes==5760000,"30-second displacement avoids ULONG product wrap");
    check(advancePcm(72000000000ull,4,0).bytes==1382400000ull,"Two-hour suspend displacement is exact");
    check(advancePcm(36000000000ull,2,0).bytes==345600000ull,"One-hour PCM16 displacement is exact");
    check(elapsedHns(1,2)==0,"Backward counter cannot underflow");
    check(elapsedHns(20,10,3)==13,"Notification time carries forward exactly");
    check(elapsedHns(~uint64_t(0),0,1)==~uint64_t(0),"Counter addition saturates safely");
}
static void reserveAndDrift(uint64_t producer_period,bool jitter){
    ses_driver::PcmRing ring;SesDriverHello hello{1,sizeof(hello),48000,1,32,480};
    check(ring.connect(hello,0),"Connect oracle producer");
    SesDriverPacket packet{1,sizeof(packet),480,0,0,{}};
    for(auto& value:packet.pcm)value=1073741824;
    for(unsigned i=0;i<3;++i){check(ring.push(packet,0),"Prefill reserve");++packet.sequence;}
    uint64_t producer=producer_period+(jitter?2000:0),consumer=0,producer_tick=1;
    std::array<int32_t,480> output{};
    while(consumer<120000000){
        if(producer<=consumer){
            check(ring.push(packet,producer/1000),"Drifting producer never overruns");++packet.sequence;++producer_tick;
            producer=producer_tick*producer_period+(jitter?(producer_tick%2?2000:8000):0);
        }else{
            ring.pull(output.data(),480,32,consumer/1000);
            for(auto value:output)if(value!=1073741824){std::fprintf(stderr,"period=%llu jitter=%u consumer=%llu producer=%llu queued=%u drift=%d underruns=%u\n",static_cast<unsigned long long>(producer_period),jitter?1u:0u,static_cast<unsigned long long>(consumer),static_cast<unsigned long long>(producer),ring.queued(),ring.drift_ppm,ring.underruns);check(false,"Steady voice survives clock drift and callback jitter");}
            check(ring.queued()<=SES_DRIVER_CAPACITY,"Reserve remains bounded");consumer+=10000;
        }
    }
    check(ring.underruns==0&&ring.silence==0,"No hidden silence or underrun during two-minute oracle");
    check(ring.queued()>300&&ring.queued()<1600,"Clock controller retains a real reserve");
    ring.pull(output.data(),480,32,producer/1000+101);
    check(output.front()==0&&output.back()==0&&ring.queued()==0,"Timeout still discards buffered voice");
}
static void workerCadence(unsigned quantum){
    ses_driver::PcmRing ring;SesDriverHello hello{1,sizeof(hello),48000,1,32,480};ring.connect(hello,0);
    ses::TransferQueue queue;std::array<float,480> source{},copied{};source.fill(.5f);
    std::array<int32_t,480> output{};SesDriverPacket packet{1,sizeof(packet),480,0,0,{}};
    bool delivered=false;uint64_t producer_tick=0,producer=2,next_consumer=0,unexpected_silence=0;
    unsigned dropped=0;
    for(uint64_t ms=0;ms<120000;++ms){
        if(ms==producer){if(!queue.push(source.data(),ms))++dropped;++producer_tick;producer=producer_tick*10+(producer_tick%2?2:8);}
        if(ms%2==0&&ring.queued()<SES_DRIVER_TARGET*2+1&&queue.take(copied.data(),ms)){
            for(unsigned i=0;i<480;++i)packet.pcm[i]=static_cast<int32_t>(copied[i]*2147483647.);
            check(ring.push(packet,ms),"Actual bridge threshold and 2ms cadence remain bounded");++packet.sequence;
        }
        if(ms==next_consumer){
            for(unsigned remaining=quantum;remaining;){
                const unsigned frames=remaining>480?480:remaining;
                ring.pull(output.data(),frames,32,ms);if(ring.primed)delivered=true;
                if(delivered)for(unsigned i=0;i<frames;++i)if(output[i]==0)++unexpected_silence;
                remaining-=frames;
            }
            next_consumer+=quantum/48;
        }
    }
    if(quantum>480){
        std::printf("20ms synchronous burst stress: %llu silence frames, %u drops; production timer drains every 1ms\n",static_cast<unsigned long long>(unexpected_silence),dropped);
        check(delivered&&ring.queued()<=SES_DRIVER_CAPACITY,"Oversized synchronous burst remains bounded");
    }else{
        if(unexpected_silence)std::fprintf(stderr,"worker quantum=%u unexpected_silence=%llu underruns=%u\n",quantum,static_cast<unsigned long long>(unexpected_silence),ring.underruns);
        check(delivered&&unexpected_silence==0&&ring.underruns==0&&dropped==0,"1/5/10ms capture cadence survives jitter after priming");
    }
}
int main(){workerTimer();clockAndFormat();reserveAndDrift(10000,true);reserveAndDrift(9990,false);reserveAndDrift(10010,false);workerCadence(48);workerCadence(240);workerCadence(480);workerCadence(960);
    std::printf("%u portable driver validation checks passed; no kernel or installation test was run\n",checks);}
