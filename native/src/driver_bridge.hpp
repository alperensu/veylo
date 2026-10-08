#pragma once
#include <windows.h>
#include <array>
#include <atomic>
#include <thread>
#include <algorithm>
#include <cmath>
#include "../../driver/shared/ses_driver_protocol.h"
#include "transfer_queue.hpp"
namespace ses {
// Only the worker calls the driver. The callback pushes into bounded SPSC storage.
class DriverBridge {
    TransferQueue queue;
    std::atomic<bool> running{false};
    HANDLE stopEvent=nullptr,ioEvent=nullptr;
    std::thread worker;
    bool call(HANDLE device,DWORD code,void* input,DWORD in,void* output,DWORD out){
        OVERLAPPED ov{};ov.hEvent=ioEvent;ResetEvent(ioEvent);DWORD bytes=0;
        BOOL ok=DeviceIoControl(device,code,input,in,output,out,&bytes,&ov);
        if(!ok&&GetLastError()==ERROR_IO_PENDING){HANDLE events[]{stopEvent,ioEvent};DWORD result=WaitForMultipleObjects(2,events,FALSE,30);
            if(result!=WAIT_OBJECT_0+1){CancelIoEx(device,&ov);WaitForSingleObject(ioEvent,INFINITE);lastError=ERROR_TIMEOUT;return false;}
            ok=GetOverlappedResult(device,&ov,&bytes,FALSE);
        }
        if(!ok){lastError=GetLastError();return false;}if(bytes!=out){lastError=ERROR_INVALID_DATA;return false;}return true;
    }
    void loop(){
        HANDLE device=INVALID_HANDLE_VALUE;uint64_t sequence=0;SesDriverPacket packet{SES_DRIVER_PROTOCOL,sizeof(packet),SES_DRIVER_FRAMES,0,0,{}};std::array<float,480> samples{};
        while(running){
            if(device==INVALID_HANDLE_VALUE){
                queue.discard();
                device=CreateFileW(SES_DRIVER_PATH,GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
                if(device==INVALID_HANDLE_VALUE){DWORD error=GetLastError();lastError=error;status=error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND?1u:error==ERROR_ACCESS_DENIED?4u:error==ERROR_SHARING_VIOLATION?5u:6u;WaitForSingleObject(stopEvent,500);continue;}
                SesDriverHello hello{SES_DRIVER_PROTOCOL,sizeof(hello),SES_DRIVER_RATE,1,32,SES_DRIVER_FRAMES};SesDriverStatus info{};
                if(!call(device,SES_IOCTL_CONNECT,&hello,sizeof(hello),&info,sizeof(info))||info.version!=SES_DRIVER_PROTOCOL||info.size!=sizeof(info)){
                    status=lastError==ERROR_REVISION_MISMATCH||info.version!=SES_DRIVER_PROTOCOL?3u:6u;CloseHandle(device);device=INVALID_HANDLE_VALUE;WaitForSingleObject(stopEvent,500);continue;}
                sequence=0;status=2;protocol=info.version;lastError=0;
            }
            SesDriverStatus info{};
            if(!call(device,SES_IOCTL_STATUS,nullptr,0,&info,sizeof(info))||info.version!=SES_DRIVER_PROTOCOL||info.size!=sizeof(info)){
                status=6;CloseHandle(device);device=INVALID_HANDLE_VALUE;continue;}
            if(info.connected!=1||info.reserved||info.queued_frames>SES_DRIVER_CAPACITY){
                lastError=ERROR_INVALID_DATA;status=6;CloseHandle(device);device=INVALID_HANDLE_VALUE;continue;}
            queued=info.queued_frames;underruns=info.underruns;overruns=info.overruns;silence=info.silence_frames;drift=info.drift_ppm;
            if(info.queued_frames<SES_DRIVER_TARGET*2+1&&queue.take(samples.data(),GetTickCount64())){
                packet.sequence=sequence;for(unsigned i=0;i<480;++i){double x=samples[i];x=std::isfinite(x)?std::clamp(x,-1.,1.):0.;packet.pcm[i]=static_cast<int32_t>(x*2147483647.);}
                if(!call(device,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0)){status=6;CloseHandle(device);device=INVALID_HANDLE_VALUE;continue;}
                ++sequence;sent+=480;
            }
            WaitForSingleObject(stopEvent,2);
        }
        if(device!=INVALID_HANDLE_VALUE)CloseHandle(device);status=0;protocol=0;queued=0;
    }
public:
    std::atomic<uint32_t> status{0},protocol{0},lastError{0},queued{0},underruns{0},overruns{0},queueDrops{0};
    std::atomic<int32_t> drift{0};std::atomic<uint64_t> sent{0},silence{0};
    ~DriverBridge(){stop();}
    void start(){stop();queue.discard();sent=0;silence=0;underruns=0;overruns=0;queueDrops=0;
        stopEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);ioEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
        if(!stopEvent||!ioEvent){stop();status=6;lastError=ERROR_NOT_ENOUGH_MEMORY;return;}
        running=true;try{worker=std::thread([this]{loop();});}catch(...){stop();status=6;lastError=ERROR_NOT_ENOUGH_MEMORY;}
    }
    void stop(){running=false;if(stopEvent)SetEvent(stopEvent);if(worker.joinable())worker.join();if(stopEvent)CloseHandle(stopEvent);if(ioEvent)CloseHandle(ioEvent);stopEvent=ioEvent=nullptr;status=0;}
    void push(const float* pcm){if(status.load(std::memory_order_acquire)==2&&!queue.push(pcm,GetTickCount64()))++queueDrops;}
    float bufferMs()const{return 20.f+float(queued.load()+queue.frames())/48.f;}
};
}
