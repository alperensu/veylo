#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "../src/driver_io.hpp"
#include "../src/driver_bridge.hpp"
#include "../../driver/shared/pcm_ring.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <string>

static std::atomic<unsigned> checks{0};
static void check(bool ok,const char* name){++checks;if(!ok){std::fprintf(stderr,"FAIL %s\n",name);std::exit(1);}}

// The production iteration helper drives a real bounded queue/ring with fake
// synchronous I/O leaves. STATUS delay advances capture, not a wall-time sleep.
struct DeliveryFixture {
    ses_driver::PcmRing ring;
    ses::TransferQueue queue;
    ses::DriverDelivery delivery;
    ses::WorkerTrace trace;
    std::array<float,480> source{},copied{};
    std::array<int32_t,960> captured{};
    SesDriverStatus lastStatus{};
    uint64_t now=0,sequence=0,tick=1;
    unsigned statusCalls=0,writeCalls=0,successfulWrites=0,delayFrames=0;
    bool writeFails=false,statusFails=false,invalidStatus=false,enqueueDuringStatus=false;
    bool wroteAfterFreeze=false,conservativeTake=false,freshTake=false;
    std::string order;
    DeliveryFixture(){
        source.fill(.25f);
        const SesDriverHello hello{SES_DRIVER_PROTOCOL,sizeof(hello),SES_DRIVER_RATE,1,32,SES_DRIVER_FRAMES};
        check(ring.connect(hello,now)&&delivery.observe(ring.status()),"Delivery fixture validates actual CONNECT baseline");
        trace.reset(true,1);trace.connected(tick++,0);
    }
    void seed(unsigned packets){
        for(unsigned n=0;n<packets;++n){
            SesDriverPacket packet{SES_DRIVER_PROTOCOL,sizeof(packet),SES_DRIVER_FRAMES,0,sequence,{}};
            for(auto& value:packet.pcm)value=536870911;
            check(ring.push(packet,now),"Seed real kernel ring without overflow");++sequence;
        }
    }
    void capture(unsigned frames){
        check(frames<=captured.size(),"Fake STATUS capture delay stays within fixed output storage");
        ring.pull(captured.data(),frames,32,now);
    }
    void nearReserve(){
        seed(3);capture(480);capture(240);
        check(ring.primed&&ring.queued()<961&&ring.queued()>600&&delivery.observe(ring.status()),
            "Actual primed ring establishes an open conservative gate near existing reserve");
    }
    void enqueue(uint64_t at){check(queue.push(source.data(),at),"Real upstream queue accepts fixture callback");}
    ses::DriverDeliveryAttempt deliver(bool gate,bool fresh){
        ses::WorkerTraceEvent event{};event.kind=ses::WorkerTraceKind::Dequeue;
        event.begin100ns=event.end100ns=tick++;event.gateOpen=gate;
        event.kernelStatusAvailable=fresh;
        if(fresh){event.kernelQueued=lastStatus.queued_frames;event.underruns=lastStatus.underruns;}
        const bool taken=gate&&queue.take(copied.data(),now);
        event.take=!gate?ses::WorkerTraceTake::NotAttempted:taken?ses::WorkerTraceTake::Packet:ses::WorkerTraceTake::EmptyOrExpired;
        trace.append(event);
        if(!taken)return ses::DriverDeliveryAttempt::Empty;
        conservativeTake|=!fresh;freshTake|=fresh;
        order+='W';++writeCalls;
        wroteAfterFreeze|=trace.reason()==ses::WorkerTraceFreeze::FirstUnderrun;
        if(writeFails)return ses::DriverDeliveryAttempt::Failed;
        SesDriverPacket packet{SES_DRIVER_PROTOCOL,sizeof(packet),SES_DRIVER_FRAMES,0,sequence,{}};
        for(unsigned i=0;i<480;++i)packet.pcm[i]=static_cast<int32_t>(copied[i]*2147483647.);
        if(!ring.push(packet,now))return ses::DriverDeliveryAttempt::Failed;
        ++sequence;++successfulWrites;return ses::DriverDeliveryAttempt::Written;
    }
    bool refresh(SesDriverStatus& info){
        order+='S';++statusCalls;
        if(delayFrames){now+=delayFrames/48;capture(delayFrames);}
        if(enqueueDuringStatus)enqueue(now);
        if(statusFails)return false;
        info=ring.status();if(invalidStatus)info.reserved=1;
        if(ses::driverStatusError(info)!=ERROR_SUCCESS)return false;
        ses::WorkerTraceEvent event{};event.kind=ses::WorkerTraceKind::Status;
        event.begin100ns=event.end100ns=tick++;event.kernelStatusAvailable=true;
        event.kernelQueued=info.queued_frames;event.underruns=info.underruns;trace.append(event);
        trace.observeUnderruns(info.underruns,tick++);lastStatus=info;return true;
    }
    ses::DriverDeliveryResult iteration(){
        return delivery.iteration([&](bool gate,bool fresh){return deliver(gate,fresh);},
            [&](SesDriverStatus& info){return refresh(info);});
    }
};
static void readyFirstDelivery(){
    using ses::DriverDeliveryResult;
    DeliveryFixture ready;ready.nearReserve();ready.enqueue(0);ready.delayFrames=864;
    check(ready.iteration()==DriverDeliveryResult::Complete&&ready.order=="WS"&&ready.conservativeTake&&
        ready.successfulWrites==1&&ready.statusCalls==1&&ready.ring.underruns==0,
        "Actual ready-first helper delivers before delayed STATUS while retaining one STATUS and one WRITE");
    check(ready.delivery.upperBound()==ready.ring.queued(),"Post-WRITE STATUS refreshes upper bound to actual captured occupancy");
    ready.trace.stopped(ready.tick++);ses::WorkerTraceEvent conservative{};
    check(ready.trace.readAfterStop(1,conservative)&&conservative.kind==ses::WorkerTraceKind::Dequeue&&
        !conservative.kernelStatusAvailable&&conservative.kernelQueued==0&&conservative.gateOpen,
        "Conservative delivery evidence is explicitly unavailable as an actual kernel STATUS");
    DeliveryFixture old;old.nearReserve();old.enqueue(0);old.delayFrames=864;
    SesDriverStatus delayed{};
    check(old.refresh(delayed)&&old.deliver(true,true)==ses::DriverDeliveryAttempt::Written&&old.order=="SW"&&old.ring.underruns==1,
        "Same real capture delay starves old STATUS-first ordering; fixture is not a claim about live failure cause");

    DeliveryFixture closed;closed.seed(3);check(closed.delivery.observe(closed.ring.status()),"Validate closed-gate occupancy baseline");
    closed.capture(480);closed.capture(240);closed.enqueue(0);
    check(closed.iteration()==DriverDeliveryResult::Complete&&closed.order=="SW"&&closed.freshTake&&!closed.conservativeTake&&
        closed.successfulWrites==1&&closed.delivery.upperBound()==closed.lastStatus.queued_frames+480&&closed.ring.overruns==0,
        "Closed conservative gate uses fresh STATUS fallback and adds successful WRITE to bound without overflow");
    closed.order.clear();closed.enqueue(0);
    check(!closed.delivery.gateOpen()&&closed.iteration()==DriverDeliveryResult::Complete&&closed.order=="S"&&closed.queue.frames()==480,
        "Bound above unchanged threshold prevents delivery when fresh STATUS also keeps gate closed");

    DeliveryFixture backlog;backlog.enqueue(0);backlog.enqueue(0);backlog.enqueue(0);
    check(backlog.iteration()==DriverDeliveryResult::Complete&&backlog.successfulWrites==1&&backlog.writeCalls==1&&
        backlog.statusCalls==1&&backlog.queue.frames()==960&&backlog.order=="WS",
        "Several ready callbacks cannot cause a second successful WRITE in the same iteration");
    DeliveryFixture arriving;arriving.enqueueDuringStatus=true;
    check(arriving.iteration()==DriverDeliveryResult::Complete&&arriving.order=="SW"&&arriving.freshTake&&arriving.successfulWrites==1,
        "Packet arriving during STATUS uses same-iteration fallback without requiring another cadence slot");

    DeliveryFixture stale;stale.now=51;stale.enqueue(0);
    check(stale.iteration()==DriverDeliveryResult::Complete&&stale.order=="S"&&stale.queue.frames()==0&&stale.successfulWrites==0,
        "Ready-first path still expires voice older than existing 50ms limit");
    DeliveryFixture exactAge;exactAge.now=50;exactAge.enqueue(0);
    check(exactAge.iteration()==DriverDeliveryResult::Complete&&exactAge.order=="WS"&&exactAge.successfulWrites==1,
        "Ready-first delivery preserves exact existing 50ms expiration boundary");

    DeliveryFixture failed;failed.enqueue(0);failed.writeFails=true;
    check(failed.iteration()==DriverDeliveryResult::WriteFailed&&failed.order=="W"&&failed.successfulWrites==0&&
        !failed.delivery.valid()&&failed.delivery.upperBound()==0&&failed.sequence==0,
        "Failed ready WRITE resets bound, retains sequence and follows failure path before any STATUS");
    DeliveryFixture failedStatus;failedStatus.enqueue(0);failedStatus.statusFails=true;
    check(failedStatus.iteration()==DriverDeliveryResult::StatusFailed&&failedStatus.order=="WS"&&
        failedStatus.successfulWrites==1&&!failedStatus.delivery.valid(),
        "STATUS failure after successful ready delivery abandons old connection bound");
    DeliveryFixture invalid;auto bad=invalid.ring.status();bad.reserved=1;
    check(!invalid.delivery.observe(bad)&&!invalid.delivery.gateOpen(),"Invalid baseline cannot authorize conservative WRITE");
    invalid.enqueue(0);invalid.invalidStatus=true;
    check(invalid.iteration()==DriverDeliveryResult::StatusFailed&&invalid.order=="S"&&invalid.writeCalls==0&&invalid.queue.frames()==480,
        "Invalid replacement STATUS never dequeues or delivers waiting upstream audio");
    invalid.invalidStatus=false;invalid.ring.disconnect();invalid.queue.discard();invalid.delivery.reset();
    const SesDriverHello hello{SES_DRIVER_PROTOCOL,sizeof(hello),SES_DRIVER_RATE,1,32,SES_DRIVER_FRAMES};
    check(!invalid.delivery.valid()&&invalid.ring.connect(hello,invalid.now)&&invalid.delivery.observe(invalid.ring.status())&&
        invalid.delivery.gateOpen()&&invalid.delivery.upperBound()==0,
        "Reconnect abandons invalid old bound and validates new zero-queued CONNECT baseline");
    invalid.sequence=0;invalid.order.clear();invalid.enqueue(invalid.now);
    check(invalid.iteration()==DriverDeliveryResult::Complete&&invalid.order=="WS"&&invalid.ring.sequence==1,
        "New connection delivers with its own reset sequence and bound");

    DeliveryFixture freeze;freeze.seed(3);check(freeze.delivery.observe(freeze.ring.status()),"Prepare closed gate for first observed underrun");
    freeze.capture(480);freeze.capture(240);freeze.enqueue(0);freeze.delayFrames=864;
    check(freeze.iteration()==DriverDeliveryResult::Complete&&freeze.order=="SW"&&freeze.wroteAfterFreeze&&
        freeze.trace.reason()==ses::WorkerTraceFreeze::FirstUnderrun&&freeze.trace.freezeOldUnderruns()==0&&
        freeze.trace.freezeNewUnderruns()==1,
        "Fresh STATUS freezes first-underrun trace before fallback WRITE or subsequent iteration work");
}

// Windows events are real; every device/IOCTL leaf is fake. This executable
// never opens a driver path, installs a device, or accesses the registry.
struct FakeApi {
    enum class Mode { Immediate, Pending, Abort, Never, CancelRace, WrongBytes, Failure, CancelFailure, PendingReady, SpuriousReady, WaitFailure };
    inline static Mode mode=Mode::Immediate;
    inline static std::mutex mutex;
    inline static unsigned created=0,closed=0,cancels=0,issues=0;
    inline static bool pending=false;
    inline static DWORD completionError=0,inputBytes=0,outputBytes=0;
    inline static void* input=nullptr;
    inline static void* output=nullptr;
    inline static DWORD* returned=nullptr;
    inline static OVERLAPPED* ov=nullptr;
    inline static HANDLE issueSignal=nullptr;
    static HANDLE event(){++created;return CreateEventW(nullptr,TRUE,FALSE,nullptr);}
    static BOOL reset(HANDLE h){return ResetEvent(h);}
    static void close(HANDLE h){++closed;CloseHandle(h);}
    static DWORD error(){return GetLastError();}
    static void completeLocked(DWORD error=0){
        if(outputBytes)std::memset(output,0x5a,outputBytes);
        *returned=outputBytes;ov->InternalHigh=outputBytes;
        completionError=error;pending=false;SetEvent(ov->hEvent);
    }
    static void complete(DWORD error=0){std::lock_guard lock(mutex);completeLocked(error);}
    static BOOL issue(HANDLE,DWORD,void* in,DWORD inBytes,void* out,DWORD outBytes,DWORD* bytes,OVERLAPPED* overlapped){
        std::lock_guard lock(mutex);++issues;
        input=in;inputBytes=inBytes;output=out;outputBytes=outBytes;returned=bytes;ov=overlapped;completionError=0;
        if(mode==Mode::Failure){pending=false;SetLastError(ERROR_ACCESS_DENIED);return FALSE;}
        if(mode==Mode::Immediate||mode==Mode::WrongBytes){completeLocked();if(mode==Mode::WrongBytes)*bytes=outBytes?outBytes-1:1;return TRUE;}
        if(mode==Mode::PendingReady){completeLocked();SetLastError(ERROR_IO_PENDING);return FALSE;}
        if(mode==Mode::SpuriousReady){pending=true;SetEvent(ov->hEvent);SetLastError(ERROR_IO_PENDING);return FALSE;}
        pending=true;if(issueSignal)SetEvent(issueSignal);SetLastError(ERROR_IO_PENDING);return FALSE;
    }
    static BOOL result(HANDLE,OVERLAPPED* overlapped,DWORD* bytes){
        std::lock_guard lock(mutex);
        check(overlapped==ov,"Completion uses the original stable OVERLAPPED");
        if(pending){SetLastError(ERROR_IO_INCOMPLETE);return FALSE;}
        if(completionError){SetLastError(completionError);return FALSE;}
        *bytes=outputBytes;return TRUE;
    }
    static BOOL cancel(HANDLE,OVERLAPPED* overlapped){
        std::lock_guard lock(mutex);++cancels;
        check(overlapped==ov,"Cancellation addresses only its own request");
        if(mode==Mode::CancelRace){completeLocked();SetLastError(ERROR_NOT_FOUND);return FALSE;}
        if(mode==Mode::CancelFailure){completeLocked(ERROR_ACCESS_DENIED);SetLastError(ERROR_ACCESS_DENIED);return FALSE;}
        if(mode!=Mode::Never)completeLocked(ERROR_OPERATION_ABORTED);
        return TRUE;
    }
    static DWORD wait(HANDLE stop,HANDLE event,DWORD ms){
        if(mode==Mode::WaitFailure){SetLastError(ERROR_INVALID_HANDLE);return WAIT_FAILED;}
        HANDLE handles[]{stop,event};return WaitForMultipleObjects(2,handles,FALSE,ms);
    }
    static DWORD grace(HANDLE event,DWORD ms){return WaitForSingleObject(event,ms);}
};
using Io=ses::BoundedDriverIo<FakeApi>;
struct Stop {HANDLE h=CreateEventW(nullptr,TRUE,FALSE,nullptr);~Stop(){CloseHandle(h);}};
static void attach(Io& io){check(io.open(),"Acquire process lease and stable request");const HANDLE device=FakeApi::event();check(device!=nullptr,"Create private fake device token");io.attach(device);}
struct PhaseClock {
    inline static std::array<uint64_t,8> ticks{10,20,30,60,70,90,100,120};
    inline static unsigned calls=0,failAt=99;
    static void reset(){ticks={10,20,30,60,70,90,100,120};calls=0;failAt=99;}
    static bool read(uint64_t& value){
        const unsigned index=calls++;
        SetLastError(ERROR_CRC); // QPC/custom observers must not replace an I/O failure.
        value=index<ticks.size()?ticks[index]:0;
        return index<ticks.size()&&index!=failAt;
    }
};
static void phaseObservations(){
    using ses::DriverIoPhases;using ses::DriverIssuePath;using ses::DriverResultPath;
    Stop stop;Io io;attach(io);std::array<unsigned char,48> output{};DriverIoPhases phases;
    auto call=[&]{return io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48,&phases,PhaseClock::read);};
    FakeApi::mode=FakeApi::Mode::Immediate;PhaseClock::reset();
    check(io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48,nullptr,PhaseClock::read)&&PhaseClock::calls==0,
        "Disabled phase observer invokes no clock even with an injected observer function");
    check(call()&&PhaseClock::calls==2&&phases.issuePath==DriverIssuePath::ImmediateSuccess&&
        phases.issue100ns==10&&phases.observations==DriverIoPhases::issueAvailable&&
        phases.waitReturn==WAIT_FAILED&&phases.resultCalls==0&&phases.resultPath==DriverResultPath::NotAttempted,
        "Immediate issue records only its wall duration and explicitly absent wait/result");
    FakeApi::mode=FakeApi::Mode::WrongBytes;PhaseClock::reset();output.fill(0x33);
    check(!call()&&io.error()==ERROR_INVALID_DATA&&output.front()==0x33&&phases.issuePath==DriverIssuePath::ImmediateSuccess,
        "Successful API issue with wrong output size remains invalid without publishing data");
    FakeApi::mode=FakeApi::Mode::Failure;PhaseClock::reset();
    check(!call()&&io.error()==ERROR_ACCESS_DENIED&&phases.issuePath==DriverIssuePath::ImmediateFailure&&PhaseClock::calls==2,
        "Immediate failure saves its LastError before observer clock clobbers it");
    FakeApi::mode=FakeApi::Mode::PendingReady;PhaseClock::reset();
    check(call()&&PhaseClock::calls==6&&phases.issuePath==DriverIssuePath::Pending&&phases.issue100ns==10&&
        phases.waitReturn==WAIT_OBJECT_0+1&&phases.wait100ns==30&&phases.result100ns==20&&phases.resultCalls==1&&
        phases.resultPath==DriverResultPath::Success&&phases.observations==15,
        "Pending path records raw completion wait and a separate successful result probe");
    FakeApi::mode=FakeApi::Mode::SpuriousReady;PhaseClock::reset();
    check(!call()&&io.error()==ERROR_TIMEOUT&&!io.fatal()&&PhaseClock::calls==8&&phases.resultCalls==2&&
        phases.result100ns==40&&phases.resultPath==DriverResultPath::Failure,
        "Incomplete completion signal records both result probes while retaining cancellation behavior");
    FakeApi::mode=FakeApi::Mode::WaitFailure;PhaseClock::reset();
    check(!call()&&io.error()==ERROR_INVALID_HANDLE&&!io.fatal()&&phases.waitReturn==WAIT_FAILED&&phases.resultCalls==1,
        "Failed pending wait retains its original error across clock and cancellation/result phases");
    SetEvent(stop.h);FakeApi::mode=FakeApi::Mode::CancelRace;PhaseClock::reset();
    check(!call()&&io.error()==ERROR_OPERATION_ABORTED&&!io.fatal()&&phases.waitReturn==WAIT_OBJECT_0&&
        phases.resultPath==DriverResultPath::Success&&phases.resultCalls==1,
        "Successful completion during cancellation remains aborted with observed stop and result phases");
    ResetEvent(stop.h);FakeApi::mode=FakeApi::Mode::Abort;PhaseClock::reset();
    check(!call()&&io.error()==ERROR_TIMEOUT&&!io.fatal()&&phases.waitReturn==WAIT_TIMEOUT&&phases.resultPath==DriverResultPath::Failure,
        "Deadline timeout records a timeout wait without changing terminal cancellation ownership");
    FakeApi::mode=FakeApi::Mode::Failure;PhaseClock::reset();PhaseClock::failAt=0;
    check(!call()&&io.error()==ERROR_ACCESS_DENIED&&phases.issue100ns==0&&phases.observations==0,
        "Clock sampling failure marks duration unavailable without replacing API failure");
    FakeApi::mode=FakeApi::Mode::Immediate;PhaseClock::reset();PhaseClock::ticks[0]=20;PhaseClock::ticks[1]=10;
    check(call()&&io.error()==ERROR_SUCCESS&&phases.observations==0&&phases.issue100ns==0,
        "Backward clock marks duration unavailable while preserving successful returned data");
    FakeApi::mode=FakeApi::Mode::PendingReady;PhaseClock::reset();PhaseClock::failAt=5;
    check(call()&&phases.resultCalls==1&&phases.resultPath==DriverResultPath::Success&&
        !(phases.observations&DriverIoPhases::resultAvailable)&&phases.result100ns==0,
        "Failed result end sample cannot invent a zero-duration successful measurement");
    FakeApi::mode=FakeApi::Mode::SpuriousReady;PhaseClock::reset();PhaseClock::ticks={0,0,0,0,0,UINT64_MAX,0,1};
    check(!call()&&io.error()==ERROR_TIMEOUT&&phases.resultCalls==2&&phases.result100ns==0&&
        !(phases.observations&DriverIoPhases::resultAvailable),"Overflow in summed result elapsed marks measurement unavailable");
    uint64_t converted=0;
    check(!ses::WorkerCadence::qpcToHns(UINT64_MAX,1,converted)&&!ses::WorkerCadence::qpcToHns(1,0,converted),
        "Phase clock conversion rejects overflow and invalid frequency");
    PhaseClock::reset();const unsigned issued=FakeApi::issues;
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,nullptr,48,&phases,PhaseClock::read)&&FakeApi::issues==issued&&
        phases.issuePath==DriverIssuePath::NotAttempted&&PhaseClock::calls==0,"Invalid request has no attempted phase or observer calls");
}
static void immediateAndValidation(){
    Stop stop;Io io;attach(io);
    std::array<unsigned char,48> output{};
    SesDriverHello hello{1,sizeof(hello),48000,1,32,480};
    check(io.call(stop.h,SES_IOCTL_CONNECT,&hello,sizeof(hello),output.data(),48),"Immediate success copies completed output");
    check(output.front()==0x5a&&output.back()==0x5a,"All and only returned output bytes copied");
    check(FakeApi::input!=&hello&&FakeApi::output!=output.data(),"Kernel input and output live in owned heap storage");
    FakeApi::mode=FakeApi::Mode::WrongBytes;
    output.fill(0x33);
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48)&&io.error()==ERROR_INVALID_DATA,"Wrong returned byte count rejected");
    check(output.front()==0x33&&output.back()==0x33,"Failed completion does not publish output");
    check(!io.call(stop.h,SES_IOCTL_CONNECT,&hello,sizeof(SesDriverPacket)+1,output.data(),48)&&io.error()==ERROR_INVALID_PARAMETER,"Oversized input rejected before copying");
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),Io::outputCapacity+1),"Oversized output rejected before issue");
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,nullptr,48),"Null output with positive size rejected");
    FakeApi::mode=FakeApi::Mode::Failure;
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48)&&io.error()==ERROR_ACCESS_DENIED&&!io.fatal(),"Immediate failure remains terminal and retryable");
    SesDriverStatus status{1,sizeof(status),1,SES_DRIVER_CAPACITY,0,0,0,0,0,0};
    check(ses::driverStatusError(status)==0,"Bounded valid status accepted");
    auto bad=status;bad.version=2;check(ses::driverStatusError(bad)==ERROR_REVISION_MISMATCH,"Wrong protocol classified precisely");
    bad=status;bad.size=47;check(ses::driverStatusError(bad)==ERROR_INVALID_DATA,"Truncated declared status rejected");
    bad=status;bad.connected=2;check(ses::driverStatusError(bad)==ERROR_INVALID_DATA,"Invalid connection state rejected");
    bad=status;bad.reserved=1;check(ses::driverStatusError(bad)==ERROR_INVALID_DATA,"Reserved bits rejected");
    bad=status;bad.queued_frames=SES_DRIVER_CAPACITY+1;check(ses::driverStatusError(bad)==ERROR_INVALID_DATA,"Unbounded queued frames rejected");
}
static void diagnosticOutput(){
    Stop stop;Io io;attach(io);FakeApi::mode=FakeApi::Mode::Immediate;
    struct GuardedDiagnostics {uint64_t before=0x11223344;SesDriverDiagnostics value{};uint64_t after=0x55667788;} output;
    check(io.call(stop.h,SES_IOCTL_DIAGNOSTICS,nullptr,0,&output.value,sizeof(output.value)),"Additive diagnostic output completes at its exact 160-byte size");
    check(output.before==0x11223344&&output.after==0x55667788,"Expanded fixed output does not overwrite neighboring caller memory");
    const auto* bytes=reinterpret_cast<const unsigned char*>(&output.value);
    check(bytes[0]==0x5a&&bytes[sizeof(output.value)-1]==0x5a,"Full additive output copied from stable heap storage");
    check(FakeApi::output!=&output.value&&FakeApi::outputBytes==sizeof(output.value),"Expanded output remains heap-owned for overlapped I/O");
    FakeApi::mode=FakeApi::Mode::WrongBytes;output.value={};
    check(!io.call(stop.h,SES_IOCTL_DIAGNOSTICS,nullptr,0,&output.value,sizeof(output.value))&&io.error()==ERROR_INVALID_DATA,"Diagnostic byte count must match its requested size exactly");
    check(output.value.version==0,"Short diagnostic completion publishes no partial structure");
    SesDriverDiagnostics info{};info.version=SES_DRIVER_DIAGNOSTICS_VERSION;info.size=sizeof(info);
    check(ses::driverDiagnosticsError(info)==0,"Valid empty diagnostic session accepted");
    auto bad=info;bad.version=2;check(ses::driverDiagnosticsError(bad)==ERROR_REVISION_MISMATCH,"Independent diagnostic version checked");
    bad=info;bad.size=48;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Legacy status size cannot impersonate diagnostics");
    bad=info;bad.reserved0=1;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"First diagnostic reserved field rejected");
    bad=info;bad.reserved1=1;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Second diagnostic reserved field rejected");
    bad=info;bad.first_underrun_present=2;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Underrun presence flag must be boolean");
    bad=info;bad.max_pull_chunk_frames=481;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Actual pull chunks retain the kernel's 480-frame bound");
    bad=info;bad.last_capture_queued_before=4097;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Diagnostic queue-before remains bounded");
    bad=info;bad.last_capture_queued_after=4097;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Diagnostic queue-after remains bounded");
    bad=info;bad.last_capture_frames=1;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Last capture cannot exceed recorded maximum");
    info.max_capture_frames=0xffffffffu;info.last_capture_frames=100000;info.max_pull_chunk_frames=480;
    check(ses::driverDiagnosticsError(info)==0,"Large original capture requests are evidence and are not capped at ring capacity");
    info.first_underrun_present=1;info.first_underrun_chunk_frames=48;info.first_underrun_remaining_frames=100000;info.first_underrun_capture_frames=100000;
    check(ses::driverDiagnosticsError(info)==0,"First underrun may belong to a large original capture request");
    bad=info;bad.first_underrun_chunk_frames=481;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"First underrun actual chunk bounded");
    bad=info;bad.first_underrun_remaining_frames=47;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Remaining request includes current pull chunk");
    bad=info;bad.first_underrun_capture_frames=99999;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"Remaining request cannot exceed original capture");
    bad=info;bad.first_underrun_queued_before=4097;check(ses::driverDiagnosticsError(bad)==ERROR_INVALID_DATA,"First underrun queue remains bounded");
    ses::DriverBridge bridge;check(!bridge.diagnosticCaptureEnabled&&!bridge.diagnosticReady&&bridge.capturedDiagnostics.version==0,"Normal product defaults to no diagnostic query");
    const uint64_t firstTicket=bridge.requestDiagnostics();
    check(firstTicket==1&&bridge.diagnosticRequestSequence==firstTicket&&!bridge.diagnosticReady&&bridge.diagnosticError==ERROR_NOT_READY,"Explicit lab request reports pending without fabricating a snapshot");
    // Reproduce an automatic query completing after an explicit request begins.
    bridge.diagnosticError=0;bridge.diagnosticReady=true;bridge.diagnosticCompletedSequence=0;
    check(bridge.diagnosticCompletedSequence!=firstTicket,"In-flight automatic completion cannot acknowledge a later explicit end query");
    bridge.diagnosticCompletedSequence=firstTicket;
    check(bridge.diagnosticCompletedSequence==firstTicket,"Explicit end completion acknowledges exactly the captured request ticket");
    const uint64_t secondTicket=bridge.requestDiagnostics();
    check(secondTicket==2&&bridge.diagnosticCompletedSequence!=secondTicket&&!bridge.diagnosticReady,"A previous successful explicit query cannot satisfy the next request");
}
static void pendingAndCancellation(){
    Stop stop;Io io;attach(io);std::array<unsigned char,48> output{};
    FakeApi::mode=FakeApi::Mode::Pending;
    FakeApi::issueSignal=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    check(FakeApi::issueSignal!=nullptr,"Private event coordinates asynchronous fake completion");
    std::thread completion([]{
        check(WaitForSingleObject(FakeApi::issueSignal,1000)==WAIT_OBJECT_0,"Asynchronous fixture observes pending issue");
        FakeApi::complete();
    });
    const bool success=io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48);completion.join();
    CloseHandle(FakeApi::issueSignal);FakeApi::issueSignal=nullptr;
    check(success&&output.front()==0x5a,"Pending completion wakes the Windows event wait");
    FakeApi::mode=FakeApi::Mode::Abort;SetEvent(stop.h);output.fill(0x22);
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48)&&io.error()==ERROR_OPERATION_ABORTED&&!io.fatal(),"Stop cancels to terminal ERROR_OPERATION_ABORTED without quarantine");
    check(output.front()==0x22,"Canceled output is never copied to caller");
    FakeApi::mode=FakeApi::Mode::CancelRace;
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48)&&!io.fatal(),"ERROR_NOT_FOUND cancellation race probes successful real completion");
    FakeApi::mode=FakeApi::Mode::CancelFailure;
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48)&&!io.fatal(),"Cancel failure plus terminal I/O error does not strand ownership");
    ResetEvent(stop.h);FakeApi::mode=FakeApi::Mode::Abort;
    check(!io.call(stop.h,SES_IOCTL_STATUS,nullptr,0,output.data(),48)&&io.error()==ERROR_TIMEOUT&&!io.fatal(),"30ms deadline cancellation can finish normally and release storage");
}
static void repeatAndLease(){
    FakeApi::mode=FakeApi::Mode::Immediate;
    const unsigned before=FakeApi::created,closed=FakeApi::closed;
    for(unsigned i=0;i<100;++i){
        Io first;attach(first);Io second;
        check(!second.open()&&second.error()==ERROR_BUSY&&!second.fatal(),"Concurrent owner fails busy without stealing first owner lease");
        first.close();check(second.open(),"Normal close releases the process lease");
    }
    check(FakeApi::created-before==FakeApi::closed-closed,"Repeated ordinary starts close every private event and device token");
    const unsigned beforeDestructor=FakeApi::closed;{Io io;attach(io);}
    check(FakeApi::closed==beforeDestructor+2,"Destructor closes exactly its own terminal event and device");
}
// A distinct fake specialization isolates the process-quarantine fixture while
// exercising the full additive output's late completion after worker exit.
struct LargeOutputApi:FakeApi {};
static void uncompletedDiagnostic(){
    using LargeIo=ses::BoundedDriverIo<LargeOutputApi>;
    Stop stop;FakeApi::mode=FakeApi::Mode::Never;SetEvent(stop.h);
    const unsigned beforeClosed=FakeApi::closed;
    void* keptOutput=nullptr;OVERLAPPED* kept=nullptr;
    {
        LargeIo io;check(io.open(),"Acquire isolated full-output lifetime fixture");io.attach(FakeApi::event());
        SesDriverDiagnostics output{};
        check(!io.call(stop.h,SES_IOCTL_DIAGNOSTICS,nullptr,0,&output,sizeof(output))&&io.fatal(),"Uncompleted additive query quarantines its full fixed output");
        check(output.version==0,"Uncompleted additive output never reaches caller");
        keptOutput=FakeApi::output;kept=FakeApi::ov;
    }
    check(FakeApi::closed==beforeClosed,"Full additive pending event and device survive worker destruction");
    FakeApi::complete();
    const auto* bytes=static_cast<const unsigned char*>(keptOutput);
    check(bytes[0]==0x5a&&bytes[sizeof(SesDriverDiagnostics)-1]==0x5a&&kept->InternalHigh==sizeof(SesDriverDiagnostics),"Late kernel writes safely cover every retained additive output byte");
    LargeIo blocked;check(!blocked.open()&&blocked.fatal(),"Full-output late completion cannot bypass quarantine restart refusal");
}
static void neverCompletes(){
    Stop stop;FakeApi::mode=FakeApi::Mode::Never;
    const unsigned beforeClosed=FakeApi::closed;
    OVERLAPPED* kept=nullptr;void* keptInput=nullptr;void* keptOutput=nullptr;HANDLE keptEvent=nullptr;
    FakeApi::issueSignal=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    check(FakeApi::issueSignal!=nullptr,"Private event marks genuinely pending worker I/O");
    std::thread worker([&]{
        Io io;attach(io);
        SesDriverHello hello{1,sizeof(hello),48000,1,32,480};SesDriverStatus output{};
        ses::DriverIoPhases phases;PhaseClock::reset();
        check(!io.call(stop.h,SES_IOCTL_CONNECT,&hello,sizeof(hello),&output,sizeof(output),&phases,PhaseClock::read),"Never-completing cancellation returns to caller");
        check(phases.issuePath==ses::DriverIssuePath::Pending&&phases.resultCalls==1&&
            phases.resultPath==ses::DriverResultPath::Incomplete&&phases.waitReturn==WAIT_OBJECT_0,
            "Quarantined cancellation preserves pending/stop/incomplete phase evidence");
        check(io.fatal()&&io.error()==ERROR_TIMEOUT&&Io::poisoned(),"Fatal timeout is latched process-wide");
        check(!io.connected(),"Fatal worker relinquishes pending request to quarantine");
        check(output.version==0,"Uncompleted output never escapes into stack caller");
        kept=FakeApi::ov;keptInput=FakeApi::input;keptOutput=FakeApi::output;keptEvent=kept->hEvent;
    });
    check(WaitForSingleObject(FakeApi::issueSignal,1000)==WAIT_OBJECT_0,"Stop test sees an actual pending worker request");
    const auto begin=std::chrono::steady_clock::now();SetEvent(stop.h);worker.join();
    const auto elapsed=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-begin).count();
    check(elapsed>=200&&elapsed<1000,"Stop joins a broken-I/O worker within bounded 250ms cancellation grace");
    CloseHandle(FakeApi::issueSignal);FakeApi::issueSignal=nullptr;
    check(FakeApi::closed==beforeClosed,"Destructor never closes quarantined request event or device");
    const unsigned beforeCreated=FakeApi::created;
    for(unsigned i=0;i<100;++i){Io blocked;check(!blocked.open()&&blocked.fatal()&&blocked.error()==ERROR_TIMEOUT,"Restart refuses permanently poisoned process slot");}
    check(FakeApi::created==beforeCreated&&FakeApi::closed==beforeClosed,"Repeated starts cannot grow quarantine storage or handles");
    // Simulate a kernel completion after stack caller and worker destruction.
    // ASan must see valid OVERLAPPED/input/output/byte-count addresses here.
    check(static_cast<SesDriverHello*>(keptInput)->rate==48000,"Quarantined input remains valid after caller destruction");
    FakeApi::complete();
    check(kept==FakeApi::ov&&keptOutput==FakeApi::output&&kept->InternalHigh==48,"Late completion safely writes original heap addresses");
    check(WaitForSingleObject(keptEvent,0)==WAIT_OBJECT_0,"Quarantined event remains valid for eventual OS completion");
    Io blocked;check(!blocked.open()&&blocked.fatal(),"Late completion never automatically reattaches poisoned process");
    std::printf("Cancellation grace measured under1000ms; retained exactly one request and two private handles until process exit\n");
}
int main(){readyFirstDelivery();immediateAndValidation();diagnosticOutput();pendingAndCancellation();phaseObservations();repeatAndLease();uncompletedDiagnostic();neverCompletes();std::printf("%u offline bounded driver I/O checks passed; no kernel driver opened\n",checks.load());}
