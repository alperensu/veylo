#pragma once
#include <windows.h>

namespace ses {
// A private one-shot timer preserves the worker's requested cadence without
// changing Windows' global timer resolution. The caller owns the stop event.
class WorkerTimer {
    HANDLE timer=nullptr;
public:
    WorkerTimer()=default;
    WorkerTimer(const WorkerTimer&)=delete;
    WorkerTimer& operator=(const WorkerTimer&)=delete;
    ~WorkerTimer(){close();}
    bool open(){
        close();
        timer=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
        return timer!=nullptr;
    }
    void close(){if(timer){CloseHandle(timer);timer=nullptr;}}
    DWORD wait(HANDLE stop,unsigned milliseconds){
        if(!timer||!stop||milliseconds==0||milliseconds>500){SetLastError(ERROR_INVALID_PARAMETER);return WAIT_FAILED;}
        LARGE_INTEGER due{};due.QuadPart=-static_cast<LONGLONG>(milliseconds)*10000;
        if(!SetWaitableTimerEx(timer,&due,0,nullptr,nullptr,nullptr,0))return WAIT_FAILED;
        HANDLE handles[]{stop,timer};
        return WaitForMultipleObjects(2,handles,FALSE,1000);
    }
};
}
