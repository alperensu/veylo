#pragma once
#include <windows.h>
#include "worker_cadence.hpp"

namespace ses {
struct WorkerWaitTiming {
    // Sample precedes SetWaitableTimerEx. Deadline is the intended QPC cadence
    // point; lateness includes pre-arm descheduling, API time and wake/resume.
    std::uint64_t scheduleSample100ns=0,wake100ns=0,deadline100ns=0,wakeLateness100ns=0;
    bool deadlineAvailable=false,wakeAvailable=false;
};
// A private one-shot timer follows anchored monotonic deadlines without
// changing Windows' global timer resolution. The caller owns the stop event.
class WorkerTimer {
    HANDLE timer=nullptr;
    std::uint64_t frequency=0;
    WorkerCadence cadence;
public:
    WorkerTimer()=default;
    WorkerTimer(const WorkerTimer&)=delete;
    WorkerTimer& operator=(const WorkerTimer&)=delete;
    ~WorkerTimer(){close();}
    bool open(){
        close();
        LARGE_INTEGER value{};
        if(!QueryPerformanceFrequency(&value)||value.QuadPart<=0||
           !WorkerCadence::validFrequency(static_cast<std::uint64_t>(value.QuadPart))){
            SetLastError(ERROR_INVALID_DATA);return false;
        }
        timer=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
        if(timer)frequency=static_cast<std::uint64_t>(value.QuadPart);
        return timer!=nullptr;
    }
    void close(){if(timer){CloseHandle(timer);timer=nullptr;}frequency=0;cadence.reset();}
    DWORD wait(HANDLE stop,unsigned milliseconds,WorkerWaitTiming* timing=nullptr){
        if(timing)*timing={};
        if(!timer||!stop||milliseconds==0||milliseconds>500){SetLastError(ERROR_INVALID_PARAMETER);return WAIT_FAILED;}
        const auto stopped=WaitForSingleObject(stop,0);
        if(stopped==WAIT_OBJECT_0||stopped==WAIT_FAILED)return stopped;
        LARGE_INTEGER counter{};std::uint64_t now=0,delay=0;
        if(!QueryPerformanceCounter(&counter)||counter.QuadPart<0||
           !WorkerCadence::qpcToHns(static_cast<std::uint64_t>(counter.QuadPart),frequency,now)||
           !cadence.delay(now,milliseconds,delay)){
            SetLastError(ERROR_INVALID_DATA);return WAIT_FAILED;
        }
        LARGE_INTEGER due{};due.QuadPart=-static_cast<LONGLONG>(delay);
        if(timing){timing->scheduleSample100ns=now;timing->deadline100ns=now+delay;timing->deadlineAvailable=true;}
        if(!SetWaitableTimerEx(timer,&due,0,nullptr,nullptr,nullptr,0))return WAIT_FAILED;
        HANDLE handles[]{stop,timer};
        const auto result=WaitForMultipleObjects(2,handles,FALSE,1000);
        const auto error=result==WAIT_FAILED?GetLastError():ERROR_SUCCESS;
        if(timing&&QueryPerformanceCounter(&counter)&&counter.QuadPart>=0&&
           WorkerCadence::qpcToHns(static_cast<std::uint64_t>(counter.QuadPart),frequency,timing->wake100ns)){
            timing->wakeAvailable=true;
            if(result==WAIT_OBJECT_0+1&&timing->wake100ns>=timing->deadline100ns)
                timing->wakeLateness100ns=timing->wake100ns-timing->deadline100ns;
        }
        if(result==WAIT_FAILED)SetLastError(error);
        return result;
    }
};
}
