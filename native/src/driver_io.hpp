#pragma once
#include <windows.h>
#include <array>
#include <atomic>
#include <cstring>
#include <memory>
#include <new>
#include "driver_io_phases.hpp"
#include "worker_cadence.hpp"
#include "../../driver/shared/ses_driver_protocol.h"

namespace ses {
inline bool driverIoClock100ns(std::uint64_t& value){
    // Initialized only by opt-in phase measurement, never by the default path.
    static const std::uint64_t frequency=[]{
        LARGE_INTEGER measured{};
        return QueryPerformanceFrequency(&measured)&&measured.QuadPart>0?static_cast<std::uint64_t>(measured.QuadPart):0;
    }();
    LARGE_INTEGER counter{};
    return QueryPerformanceCounter(&counter)&&counter.QuadPart>=0&&
        WorkerCadence::qpcToHns(static_cast<std::uint64_t>(counter.QuadPart),frequency,value);
}
struct WindowsDriverIo {
    static HANDLE event(){return CreateEventW(nullptr,TRUE,FALSE,nullptr);}
    static BOOL reset(HANDLE h){return ResetEvent(h);}
    static void close(HANDLE h){CloseHandle(h);}
    static DWORD error(){return GetLastError();}
    static BOOL issue(HANDLE h,DWORD code,void* input,DWORD in,void* output,DWORD out,DWORD* bytes,OVERLAPPED* ov){return DeviceIoControl(h,code,input,in,output,out,bytes,ov);}
    static BOOL result(HANDLE h,OVERLAPPED* ov,DWORD* bytes){return GetOverlappedResult(h,ov,bytes,FALSE);}
    static BOOL cancel(HANDLE h,OVERLAPPED* ov){return CancelIoEx(h,ov);}
    static DWORD wait(HANDLE stop,HANDLE event,DWORD ms){HANDLE handles[]{stop,event};return WaitForMultipleObjects(2,handles,FALSE,ms);}
    static DWORD grace(HANDLE event,DWORD ms){return WaitForSingleObject(event,ms);}
};

inline DWORD driverStatusError(const SesDriverStatus& info){
    if(info.version!=SES_DRIVER_PROTOCOL)return ERROR_REVISION_MISMATCH;
    if(info.size!=sizeof(info)||info.connected!=1||info.reserved||info.queued_frames>SES_DRIVER_CAPACITY)return ERROR_INVALID_DATA;
    return ERROR_SUCCESS;
}
inline DWORD driverDiagnosticsError(const SesDriverDiagnostics& info){
    if(info.version!=SES_DRIVER_DIAGNOSTICS_VERSION)return ERROR_REVISION_MISMATCH;
    if(info.size!=sizeof(info)||info.reserved0||info.reserved1||info.first_underrun_present>1||
       info.max_pull_chunk_frames>SES_DRIVER_FRAMES||info.last_capture_queued_before>SES_DRIVER_CAPACITY||
       info.last_capture_queued_after>SES_DRIVER_CAPACITY||info.last_capture_frames>info.max_capture_frames)return ERROR_INVALID_DATA;
    if(info.first_underrun_present&&(info.first_underrun_queued_before>SES_DRIVER_CAPACITY||
       info.first_underrun_chunk_frames>SES_DRIVER_FRAMES||info.first_underrun_chunk_frames>info.first_underrun_remaining_frames||
       info.first_underrun_remaining_frames>info.first_underrun_capture_frames))return ERROR_INVALID_DATA;
    return ERROR_SUCCESS;
}

// One worker owns the process-wide I/O slot. A broken cancellation permanently
// consumes it: at most one stable request and its two handles survive until OS
// process cleanup. There is deliberately no destructor/reaper for quarantine.
// CancelIoEx is only a request, and ERROR_NOT_FOUND does not prove completion.
// The native module remains loaded for the process lifetime (the product uses
// a persistent DllImport resolver); unloading/reloading it is not supported.
template<class Api=WindowsDriverIo> class BoundedDriverIo {
public:
    static constexpr size_t outputCapacity=sizeof(SesDriverDiagnostics)>sizeof(SesDriverStatus)?sizeof(SesDriverDiagnostics):sizeof(SesDriverStatus);
    static_assert(outputCapacity<=256);
private:
    struct Request {
        OVERLAPPED overlapped{};
        std::array<unsigned char,sizeof(SesDriverPacket)> input{};
        std::array<unsigned char,outputCapacity> output{};
        HANDLE device=INVALID_HANDLE_VALUE;
        HANDLE event=nullptr;
        DWORD issuedBytes=0;
    };
    inline static std::atomic<bool> occupied{false};
    inline static std::atomic<Request*> quarantine{nullptr};
    std::unique_ptr<Request> request;
    bool owns=false,failed=false;
    DWORD failure=ERROR_SUCCESS;
    static bool incomplete(DWORD error){return error==ERROR_IO_INCOMPLETE||error==ERROR_IO_PENDING;}
    bool abandon(){
        failed=true;failure=ERROR_TIMEOUT;
        quarantine.store(request.release(),std::memory_order_release);
        owns=false; // occupied stays true forever; future starts fail closed.
        return false;
    }
public:
    static constexpr DWORD deadlineMs=30,cancelGraceMs=250;
    BoundedDriverIo()=default;
    BoundedDriverIo(const BoundedDriverIo&)=delete;
    BoundedDriverIo& operator=(const BoundedDriverIo&)=delete;
    ~BoundedDriverIo(){close();}
    static bool poisoned(){return quarantine.load(std::memory_order_acquire)!=nullptr;}
    bool fatal()const{return failed;}
    DWORD error()const{return failure;}
    bool open(){
        close();
        if(poisoned()){failed=true;failure=ERROR_TIMEOUT;return false;}
        bool expected=false;
        if(!occupied.compare_exchange_strong(expected,true,std::memory_order_acq_rel)){failure=ERROR_BUSY;return false;}
        owns=true;failed=false;failure=ERROR_SUCCESS;
        request.reset(new(std::nothrow) Request);
        if(!request){failure=ERROR_NOT_ENOUGH_MEMORY;close();return false;}
        request->event=Api::event();
        if(!request->event){failure=Api::error();close();return false;}
        return true;
    }
    void disconnect(){if(request&&request->device!=INVALID_HANDLE_VALUE){Api::close(request->device);request->device=INVALID_HANDLE_VALUE;}}
    void attach(HANDLE device){disconnect();if(request)request->device=device;}
    bool connected()const{return request&&request->device!=INVALID_HANDLE_VALUE;}
    void close(){
        disconnect();
        if(request&&request->event)Api::close(request->event);
        request.reset();
        if(owns){owns=false;occupied.store(false,std::memory_order_release);}
    }
    bool call(HANDLE stop,DWORD code,const void* input,DWORD in,void* output,DWORD out,
              DriverIoPhases* phases=nullptr,DriverIoClock clock=driverIoClock100ns){
        if(phases)*phases={};
        // No clock calls or allocations occur when the observer is absent.
        auto sample=[&](std::uint64_t& value){return phases&&clock&&clock(value);};
        auto duration=[&](std::uint64_t begin,bool available,std::uint64_t& elapsed,std::uint8_t flag){
            std::uint64_t end=0;
            if(sample(end)&&available&&end>=begin){elapsed=end-begin;phases->observations|=flag;}
        };
        if(failed)return false;
        if(!connected()||!stop||in>sizeof(request->input)||out>sizeof(request->output)||(in&&!input)||(out&&!output)){
            failure=ERROR_INVALID_PARAMETER;return false;
        }
        auto& r=*request;
        r.overlapped={};r.overlapped.hEvent=r.event;
        if(!Api::reset(r.event)){failure=Api::error();return false;}
        if(in)std::memcpy(r.input.data(),input,in);
        r.output.fill(0);
        r.issuedBytes=0;
        std::uint64_t begin=0;
        const bool issueSample=sample(begin);
        BOOL ok=Api::issue(r.device,code,in?r.input.data():nullptr,in,out?r.output.data():nullptr,out,&r.issuedBytes,&r.overlapped);
        DWORD error=ok?ERROR_SUCCESS:Api::error(); // Before any optional clock can alter LastError.
        if(phases){
            phases->issuePath=ok?DriverIssuePath::ImmediateSuccess:error==ERROR_IO_PENDING?DriverIssuePath::Pending:DriverIssuePath::ImmediateFailure;
            duration(begin,issueSample,phases->issue100ns,DriverIoPhases::issueAvailable);
        }
        DWORD bytes=r.issuedBytes;
        auto result=[&]{
            std::uint64_t started=0,elapsed=0;
            const bool available=sample(started);
            const BOOL completed=Api::result(r.device,&r.overlapped,&bytes);
            error=completed?ERROR_SUCCESS:Api::error(); // Preserve failed result before the end sample.
            if(phases){
                const auto previousFlags=phases->observations;
                phases->observations&=static_cast<std::uint8_t>(~DriverIoPhases::resultAvailable);
                duration(started,available,elapsed,DriverIoPhases::resultAvailable);
                const bool valid=(phases->observations&DriverIoPhases::resultAvailable)&&
                    (!phases->resultCalls||(previousFlags&DriverIoPhases::resultAvailable))&&
                    phases->result100ns<=UINT64_MAX-elapsed;
                if(valid)phases->result100ns+=elapsed;
                else{phases->result100ns=0;phases->observations&=static_cast<std::uint8_t>(~DriverIoPhases::resultAvailable);}
                ++phases->resultCalls;
                phases->resultPath=completed?DriverResultPath::Success:incomplete(error)?DriverResultPath::Incomplete:DriverResultPath::Failure;
            }
            return completed;
        };
        if(!ok){
            if(error!=ERROR_IO_PENDING){failure=error;return false;}
            const bool waitSample=sample(begin);
            const DWORD waited=Api::wait(stop,r.event,deadlineMs);
            const DWORD waitError=waited==WAIT_FAILED?Api::error():ERROR_SUCCESS;
            if(phases){phases->waitReturn=waited;phases->observations|=DriverIoPhases::waitAttempted;
                duration(begin,waitSample,phases->wait100ns,DriverIoPhases::waitAvailable);}
            if(waited==WAIT_OBJECT_0+1){
                ok=result();
                if(!ok&&!incomplete(error)){failure=error;return false;}
            }
            if(waited!=WAIT_OBJECT_0+1||!ok){
                const DWORD reason=waited==WAIT_OBJECT_0?ERROR_OPERATION_ABORTED:waited==WAIT_FAILED?waitError:ERROR_TIMEOUT;
                Api::cancel(r.device,&r.overlapped);
                // The stop event is already signaled here; wait on completion only.
                Api::grace(r.event,cancelGraceMs);
                ok=result();
                if(!ok&&incomplete(error))return abandon();
                failure=reason;return false; // Even a successful cancel race exceeded our deadline.
            }
        }
        if(bytes!=out){failure=ERROR_INVALID_DATA;return false;}
        if(out)std::memcpy(output,r.output.data(),out);
        failure=ERROR_SUCCESS;return true;
    }
};
}
