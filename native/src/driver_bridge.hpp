#pragma once
#include <windows.h>
#include <avrt.h>
#include <array>
#include <atomic>
#include <thread>
#include <algorithm>
#include <cmath>
#include "../../driver/shared/ses_driver_protocol.h"
#include "transfer_queue.hpp"
#include "worker_timer.hpp"
#include "driver_io.hpp"
namespace ses {
// Registration and DLL lifetime belong to the worker, never the audio callback.
class DriverWorkerMmcss {
    HMODULE module=nullptr;
    HANDLE task=nullptr;
    decltype(&AvRevertMmThreadCharacteristics) revert=nullptr;
public:
    bool ready=false;
    DriverWorkerMmcss(){
        module=LoadLibraryExW(L"avrt.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
        if(!module)return;
        const auto set=reinterpret_cast<decltype(&AvSetMmThreadCharacteristicsW)>(GetProcAddress(module,"AvSetMmThreadCharacteristicsW"));
        const auto priority=reinterpret_cast<decltype(&AvSetMmThreadPriority)>(GetProcAddress(module,"AvSetMmThreadPriority"));
        revert=reinterpret_cast<decltype(revert)>(GetProcAddress(module,"AvRevertMmThreadCharacteristics"));
        if(!set||!priority||!revert)return;
        DWORD index=0;task=set(L"Pro Audio",&index);
        ready=task&&priority(task,AVRT_PRIORITY_HIGH);
    }
    DriverWorkerMmcss(const DriverWorkerMmcss&)=delete;
    DriverWorkerMmcss& operator=(const DriverWorkerMmcss&)=delete;
    ~DriverWorkerMmcss(){if(task&&revert)revert(task);if(module)FreeLibrary(module);}
};
// Only the worker calls the driver. The callback pushes into bounded SPSC storage.
class DriverBridge {
    TransferQueue queue;
    std::atomic<bool> running{false};
    std::atomic<bool> fatalIo{false};
    HANDLE stopEvent=nullptr;
    WorkerTimer cadence;
    std::thread worker;
    static uint64_t qpc100ns(){
        LARGE_INTEGER counter{},frequency{};QueryPerformanceCounter(&counter);QueryPerformanceFrequency(&frequency);
        return static_cast<uint64_t>(counter.QuadPart/frequency.QuadPart)*10000000+
            static_cast<uint64_t>(counter.QuadPart%frequency.QuadPart)*10000000/static_cast<uint64_t>(frequency.QuadPart);
    }
    bool call(BoundedDriverIo<>& io,DWORD code,const void* input,DWORD in,void* output,DWORD out){
        const uint64_t begin=qpc100ns();
        const bool ok=io.call(stopEvent,code,input,in,output,out);
        const uint64_t end=qpc100ns(),duration=end-begin;
        if(duration>maxIoctl100ns.load())maxIoctl100ns=duration;
        if(!ok){lastError=io.error();if(io.fatal()){fatalIo=true;status=6;}return false;}
        if(code==SES_IOCTL_WRITE){
            const uint64_t previous=lastWriteCompletion100ns.exchange(end);
            const uint64_t gap=previous?end-previous:0;lastWriteGap100ns=gap;
            if(gap>maxWriteGap100ns.load())maxWriteGap100ns=gap;
        }
        return true;
    }
    bool validStatus(const SesDriverStatus& info){const DWORD error=driverStatusError(info);if(error){lastError=error;return false;}return true;}
    void publishCounters(const SesDriverStatus& info){
        queued=info.queued_frames;received=info.received_frames;underruns=info.underruns;overruns=info.overruns;silence=info.silence_frames;drift=info.drift_ppm;
    }
    void loop(){
        BoundedDriverIo<> io;
        if(!io.open()){lastError=io.error();fatalIo=io.fatal();status=6;return;}
        DriverWorkerMmcss mmcss;workerMmcss=mmcss.ready;
        uint64_t sequence=0;SesDriverPacket packet{SES_DRIVER_PROTOCOL,sizeof(packet),SES_DRIVER_FRAMES,0,0,{}};std::array<float,480> samples{};
        while(running){
            if(!io.connected()){
                queue.discard();
                const HANDLE device=CreateFileW(SES_DRIVER_PATH,GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
                if(device==INVALID_HANDLE_VALUE){DWORD error=GetLastError();lastError=error;status=error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND?1u:error==ERROR_ACCESS_DENIED?4u:error==ERROR_SHARING_VIOLATION?5u:6u;WaitForSingleObject(stopEvent,500);continue;}
                io.attach(device);
                SesDriverHello hello{SES_DRIVER_PROTOCOL,sizeof(hello),SES_DRIVER_RATE,1,32,SES_DRIVER_FRAMES};SesDriverStatus info{};
                if(!call(io,SES_IOCTL_CONNECT,&hello,sizeof(hello),&info,sizeof(info))||!validStatus(info)){
                    if(io.fatal())break;
                    status=lastError==ERROR_REVISION_MISMATCH?3u:6u;io.disconnect();WaitForSingleObject(stopEvent,500);continue;}
                sequence=0;publishCounters(info);protocol=info.version;lastError=0;status=2;
            }
            SesDriverStatus info{};
            if(!call(io,SES_IOCTL_STATUS,nullptr,0,&info,sizeof(info))||!validStatus(info)){
                status=6;if(io.fatal())break;io.disconnect();continue;}
            publishCounters(info);
            if(info.queued_frames<SES_DRIVER_TARGET*2+1&&queue.take(samples.data(),GetTickCount64())){
                packet.sequence=sequence;for(unsigned i=0;i<480;++i){double x=samples[i];x=std::isfinite(x)?std::clamp(x,-1.,1.):0.;packet.pcm[i]=static_cast<int32_t>(x*2147483647.);}
                if(!call(io,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0)){status=6;if(io.fatal())break;io.disconnect();continue;}
                ++sequence;sent+=480;
            }
            const DWORD idle=cadence.wait(stopEvent,2);
            if(idle!=WAIT_OBJECT_0+1){
                if(running){lastError=idle==WAIT_FAILED?GetLastError():ERROR_TIMEOUT;status=6;}
                break;
            }
        }
        io.close();workerMmcss=false;if(!running&&!fatalIo)status=0;protocol=0;queued=0;
    }
public:
    std::atomic<uint32_t> status{0},protocol{0},lastError{0},queued{0},underruns{0},overruns{0},queueDrops{0};
    std::atomic<bool> workerMmcss{false};
    std::atomic<int32_t> drift{0};std::atomic<uint64_t> sent{0},received{0},silence{0};
    std::atomic<uint64_t> maxIoctl100ns{0},lastWriteCompletion100ns{0},lastWriteGap100ns{0},maxWriteGap100ns{0};
    ~DriverBridge(){stop();}
    void start(){stop();
        if(BoundedDriverIo<>::poisoned()){fatalIo=true;status=6;lastError=ERROR_TIMEOUT;return;}
        fatalIo=false;queue.discard();sent=0;received=0;silence=0;underruns=0;overruns=0;queueDrops=0;
        maxIoctl100ns=0;lastWriteCompletion100ns=0;lastWriteGap100ns=0;maxWriteGap100ns=0;
        auto failStart=[this](DWORD error){stop();status=6;lastError=error;};
        stopEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
        if(!stopEvent){failStart(GetLastError());return;}
        if(!cadence.open()){failStart(GetLastError());return;}
        running=true;try{worker=std::thread([this]{loop();});}catch(...){stop();status=6;lastError=ERROR_NOT_ENOUGH_MEMORY;}
    }
    void stop(){running=false;if(stopEvent)SetEvent(stopEvent);if(worker.joinable())worker.join();cadence.close();if(stopEvent)CloseHandle(stopEvent);stopEvent=nullptr;workerMmcss=false;if(!fatalIo)status=0;}
    void push(const float* pcm){if(status.load(std::memory_order_acquire)==2&&!queue.push(pcm,GetTickCount64()))++queueDrops;}
    float bufferMs()const{return 20.f+float(queued.load()+queue.frames())/48.f;}
};
}
