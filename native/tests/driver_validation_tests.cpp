#include "../../driver/shared/audio_validation.h"
#include "../../driver/shared/pcm_ring.h"
#include "../../driver/shared/capture_diagnostics.h"
#include "../src/transfer_queue.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "../src/worker_timer.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <cstddef>
#include <type_traits>
static_assert(std::is_standard_layout_v<SesDriverDiagnostics>&&std::is_trivially_copyable_v<SesDriverDiagnostics>);
static_assert(sizeof(SesDriverDiagnostics)==160&&sizeof(SesDriverDiagnostics)<=256);
static_assert(offsetof(SesDriverDiagnostics,capture_calls)==8);
static_assert(offsetof(SesDriverDiagnostics,first_underrun_tick_hns)==112);
static_assert((SES_IOCTL_DIAGNOSTICS&3u)==0u); // METHOD_BUFFERED
static_assert(((SES_IOCTL_DIAGNOSTICS>>14)&3u)==3u); // Same read/write access
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
struct DiagnosticUnderrun {SesDriverStatus before{},after{};uint32_t remaining=0;};
static DiagnosticUnderrun diagnosticCapture(ses_driver::CaptureDiagnostics& diagnostics,
                                           ses_driver::PcmRing& ring,uint32_t frames,uint64_t tick_hns){
    const auto token=diagnostics.beginCapture(ring.attached,frames,ring.queued(),tick_hns);
    std::array<int32_t,SES_DRIVER_FRAMES> output{};DiagnosticUnderrun event{};
    for(uint32_t remaining=frames;remaining;){
        const uint32_t chunk=remaining>SES_DRIVER_FRAMES?SES_DRIVER_FRAMES:remaining;
        const auto before=ring.status();const bool primed=ring.primed;
        ring.pull(output.data(),chunk,32,tick_hns/10000);const auto after=ring.status();
        diagnostics.pulled(token,ring.attached,primed,chunk,remaining,tick_hns,before,after);
        if(!event.remaining&&primed&&before.underruns!=after.underruns)event={before,after,remaining};
        if(remaining==chunk)diagnostics.endCapture(token,ring.attached,ring.queued());
        remaining-=chunk;
    }
    return event;
}
static void captureDiagnostics(){
    using namespace ses_driver;
    CaptureDiagnostics diagnostics;PcmRing ring;
    const auto initial=diagnostics.snapshot();
    check(validCaptureDiagnostics(initial),"Diagnostic wire version, size, and reserved fields are initialized");
    auto invalid=initial;invalid.version=2;check(!validCaptureDiagnostics(invalid),"Unknown diagnostics version rejected");
    invalid=initial;invalid.size=sizeof(invalid)-1;check(!validCaptureDiagnostics(invalid),"Truncated diagnostics layout rejected");
    invalid=initial;invalid.reserved0=1;check(!validCaptureDiagnostics(invalid),"Nonzero first diagnostics reserved word rejected");
    invalid=initial;invalid.reserved1=1;check(!validCaptureDiagnostics(invalid),"Nonzero second diagnostics reserved word rejected");
    diagnosticCapture(diagnostics,ring,1920,5000000);
    diagnostics.successfulWrite(false,5000000);
    check(diagnostics.snapshot().capture_calls==0&&diagnostics.snapshot().total_requested_frames==0&&
          diagnostics.snapshot().last_successful_write_tick_hns==0,"Disconnected capture baseline and writes are excluded");
    check(diagnostics.beginCapture(true,0,0,0)==0,"Empty capture does not count as a source call");
    SesDriverHello hello{1,sizeof(hello),48000,1,32,480};
    SesDriverPacket packet{1,sizeof(packet),480,0,0,{}};packet.pcm[0]=1073741824;
    check(ring.connect(hello,0),"Connect diagnostics nominal fixture");diagnostics.reset();
    for(unsigned i=0;i<3;++i){check(ring.push(packet,0),"Prefill diagnostics nominal fixture");++packet.sequence;diagnostics.successfulWrite(true,0);}
    for(unsigned ms=0;ms<1000;++ms){
        if(ms&&ms%10==0){check(ring.push(packet,ms),"Write diagnostics nominal fixture");++packet.sequence;diagnostics.successfulWrite(true,ms*10000ull);}
        diagnosticCapture(diagnostics,ring,48,ms*10000ull);
    }
    const auto nominal=diagnostics.snapshot();
    check(nominal.capture_calls==1000&&nominal.total_requested_frames==48000&&
          nominal.max_capture_frames==48&&nominal.max_pull_chunk_frames==48,"1000 nominal 48-frame pulls retain whole-call totals");
    check(!nominal.first_underrun_present&&ring.underruns==0,"Nominal diagnostics do not invent an underrun");
    check(nominal.last_capture_frames==48&&nominal.last_capture_tick_hns==9990000&&
          nominal.last_capture_queued_after==ring.queued()&&nominal.last_capture_queued_before>=nominal.last_capture_queued_after,
          "Last nominal call has its own tick and exact before/after queue");
    check(nominal.last_successful_write_tick_hns==9900000&&nominal.last_successful_write_gap_hns==100000&&
          nominal.max_successful_write_gap_hns==100000,"Successful write arrival gaps use 100ns units");
    check(ring.status().reserved==0&&sizeof(SesDriverStatus)==48,"Legacy status reserved and size remain unchanged");

    // A delayed whole-call request must remain visible even though each pull is
    // bounded to 480 frames. Snapshot counters are ring lifetime values.
    check(ring.connect(hello,1000),"Reconnect diagnostics delayed fixture");diagnostics.reset();packet.sequence=0;
    for(unsigned i=0;i<3;++i){check(ring.push(packet,1000),"Prefill diagnostics delayed fixture");++packet.sequence;diagnostics.successfulWrite(true,10000000);}
    diagnosticCapture(diagnostics,ring,48,10000000);
    const auto queue_before=ring.queued();
    const auto event=diagnosticCapture(diagnostics,ring,1920,10200000);
    const auto delayed=diagnostics.snapshot();
    check(event.remaining!=0&&delayed.first_underrun_present==1,"Oversized delayed capture records a real first steady underrun");
    check(delayed.capture_calls==2&&delayed.total_requested_frames==1968&&delayed.max_capture_frames==1920&&
          delayed.max_pull_chunk_frames==480,"Delayed 1920-frame call is not mislabeled as four ordinary pulls");
    check(delayed.last_capture_frames==1920&&delayed.last_capture_queued_before==queue_before&&
          delayed.last_capture_queued_after==ring.queued()&&delayed.last_capture_tick_hns==10200000,
          "Whole delayed call queue and tick survive chunk splitting");
    check(delayed.first_underrun_capture_frames==1920&&delayed.first_underrun_chunk_frames==480&&
          delayed.first_underrun_remaining_frames==event.remaining&&delayed.first_underrun_queued_before==event.before.queued_frames,
          "First underrun preserves original-call, chunk, remaining, and exact queued context");
    check(delayed.first_underrun_old_count==event.before.underruns&&delayed.first_underrun_new_count==event.after.underruns&&
          delayed.first_underrun_received_frames==event.after.received_frames&&
          delayed.first_underrun_silence_before==event.before.silence_frames&&delayed.first_underrun_silence_after==event.after.silence_frames,
          "First underrun snapshots exact cumulative received, silence, and counter transition");
    check(delayed.first_underrun_tick_hns==10200000&&delayed.first_underrun_successful_write_tick_hns==10000000&&
          delayed.first_underrun_since_successful_write_hns==200000,"First underrun retains successful write arrival age");
    const auto sticky=delayed.first_underrun_silence_after;
    diagnosticCapture(diagnostics,ring,480,10210000);
    check(diagnostics.snapshot().first_underrun_silence_after==sticky&&
          diagnostics.snapshot().first_underrun_tick_hns==10200000,"Later starvation cannot overwrite the first underrun event");

    const auto stale=diagnostics.beginCapture(true,1920,42,10300000);
    diagnostics.reset();diagnostics.successfulWrite(true,10350000);
    diagnostics.pulled(stale,true,true,480,1440,10400000,event.before,event.after);
    diagnostics.endCapture(stale,true,7);
    const auto reset=diagnostics.snapshot();
    check(reset.capture_calls==0&&reset.total_requested_frames==0&&!reset.first_underrun_present&&
          reset.last_capture_frames==0&&reset.last_capture_queued_after==0&&reset.max_pull_chunk_frames==0,
          "CONNECT reset excludes in-flight old-session chunks and clears source-session diagnostics");
    const auto fresh=diagnostics.beginCapture(true,48,100,10400000);
    diagnostics.pulled(fresh,true,false,48,48,10400000,event.before,event.after);
    diagnostics.endCapture(fresh,true,52);
    check(diagnostics.snapshot().capture_calls==1&&!diagnostics.snapshot().first_underrun_present&&
          diagnostics.snapshot().last_capture_queued_after==52,"New-session capture resumes and unprimed silence is excluded");
    const auto ignored=diagnostics.beginCapture(false,480,0,10500000);
    diagnostics.pulled(ignored,false,true,480,480,10500000,event.before,event.after);
    diagnostics.endCapture(ignored,false,0);
    check(diagnostics.snapshot().capture_calls==1&&!diagnostics.snapshot().first_underrun_present,
          "Disconnected chunks cannot become source-session underrun evidence");
    check(CaptureDiagnostics::saturatingAdd(~uint64_t(0)-3,4)==~uint64_t(0)&&
          CaptureDiagnostics::saturatingAdd(~uint64_t(0),1)==~uint64_t(0),"Diagnostics counters saturate rather than wrap");
    check(CaptureDiagnostics::elapsed(1,2)==0&&CaptureDiagnostics::elapsed(20,10)==10,
          "Write-age arithmetic cannot underflow on backward ticks");
    diagnostics.successfulWrite(true,10349999);
    check(diagnostics.snapshot().last_successful_write_gap_hns==0,"Backward simulated write tick cannot create a huge gap");
}
int main(){workerTimer();clockAndFormat();reserveAndDrift(10000,true);reserveAndDrift(9990,false);reserveAndDrift(10010,false);workerCadence(48);workerCadence(240);workerCadence(480);workerCadence(960);captureDiagnostics();
    std::printf("%u portable driver validation checks passed; no kernel or installation test was run\n",checks);}
