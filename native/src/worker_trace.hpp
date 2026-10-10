#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace ses {
enum class WorkerTraceKind : std::uint32_t { Connect=1, Status=2, Write=3, Dequeue=4, Wait=5, Connection=6 };
enum class WorkerTraceFreeze : std::uint32_t { None=0, FirstUnderrun=1, TerminalRequest=2, WorkerStopped=3 };
enum class WorkerTraceTake : std::uint32_t { NotAttempted=0, EmptyOrExpired=1, Packet=2 };
// Numeric lab evidence only. Queue counts are independently sampled observations,
// not an atomic snapshot of the callback queue and the kernel ring together.
struct WorkerTraceEvent {
    std::uint64_t begin100ns=0,end100ns=0,deadline100ns=0,wakeLateness100ns=0,scheduleSample100ns=0;
    std::uint32_t connectionGeneration=0,result=0,kernelQueued=0,underruns=0;
    std::uint32_t upstreamBefore=0,upstreamAfter=0;
    std::uint32_t waitError=0;
    WorkerTraceKind kind=WorkerTraceKind::Status;
    WorkerTraceTake take=WorkerTraceTake::NotAttempted;
    bool gateOpen=false,deadlineAvailable=false,wakeLatenessAvailable=false;
    bool kernelStatusAvailable=false,upstreamSamplesAvailable=false;
};
// Exactly one worker mutates this ring. Readers must obtain a copy after join;
// completion of an IOCTL/request ticket does not make this storage safe to read.
class WorkerTrace {
    std::array<WorkerTraceEvent,128> events{};
    std::size_t count_=0,next=0;
    std::uint64_t overwritten_=0,rejected_=0,startGeneration_=0,freeze100ns_=0,lastEnd=0;
    std::uint32_t connectionGeneration_=0,previousUnderruns=0,freezeOld_=0,freezeNew_=0;
    WorkerTraceFreeze reason_=WorkerTraceFreeze::None;
    bool enabled_=false,stopped_=true,haveConnection=false;
public:
    static constexpr std::size_t capacity=128;
    void reset(bool enabled,std::uint64_t startGeneration){
        count_=next=0;overwritten_=rejected_=freeze100ns_=lastEnd=0;
        startGeneration_=startGeneration;connectionGeneration_=previousUnderruns=freezeOld_=freezeNew_=0;
        reason_=WorkerTraceFreeze::None;enabled_=enabled;stopped_=false;haveConnection=false;
    }
    bool recording()const{return enabled_&&!stopped_&&reason_==WorkerTraceFreeze::None;}
    bool append(WorkerTraceEvent event){
        if(!recording())return false;
        if(event.end100ns<event.begin100ns||event.begin100ns<lastEnd||
           static_cast<std::uint32_t>(event.kind)<1||static_cast<std::uint32_t>(event.kind)>6||
           static_cast<std::uint32_t>(event.take)>2||
           (event.deadlineAvailable&&(event.kind!=WorkerTraceKind::Wait||event.scheduleSample100ns<event.begin100ns||
               event.scheduleSample100ns>event.end100ns||event.deadline100ns<=event.scheduleSample100ns))||
           (event.wakeLatenessAvailable&&(!event.deadlineAvailable||
               event.wakeLateness100ns!=(event.end100ns>event.deadline100ns?event.end100ns-event.deadline100ns:0)))){
            ++rejected_;return false;
        }
        event.connectionGeneration=connectionGeneration_;
        events[next]=event;next=(next+1)%capacity;
        if(count_<capacity)++count_;else ++overwritten_;
        lastEnd=event.end100ns;return true;
    }
    void connected(std::uint64_t now,std::uint32_t underruns){
        if(!recording())return;
        ++connectionGeneration_;previousUnderruns=underruns;haveConnection=true;
        WorkerTraceEvent event{};event.kind=WorkerTraceKind::Connection;
        event.begin100ns=event.end100ns=now;event.underruns=underruns;append(event);
    }
    bool freeze(WorkerTraceFreeze reason,std::uint64_t now){
        if(!recording()||reason==WorkerTraceFreeze::None||
           static_cast<std::uint32_t>(reason)>3||now<lastEnd)return false;
        reason_=reason;freeze100ns_=now;return true;
    }
    bool observeUnderruns(std::uint32_t current,std::uint64_t now){
        if(!recording()||!haveConnection)return false;
        const auto previous=previousUnderruns;previousUnderruns=current;
        if(current<=previous)return false;
        if(!freeze(WorkerTraceFreeze::FirstUnderrun,now))return false;
        freezeOld_=previous;freezeNew_=current;return true;
    }
    void stopped(std::uint64_t now){
        freeze(WorkerTraceFreeze::WorkerStopped,now);stopped_=true;
    }
    bool readAfterStop(std::size_t index,WorkerTraceEvent& event)const{
        if(!stopped_||index>=count_)return false;
        event=events[(next+capacity-count_+index)%capacity];return true;
    }
    bool isStopped()const{return stopped_;}
    bool enabled()const{return enabled_;}
    std::size_t count()const{return count_;}
    std::uint64_t overwritten()const{return overwritten_;}
    std::uint64_t rejected()const{return rejected_;}
    std::uint64_t startGeneration()const{return startGeneration_;}
    std::uint32_t connectionGeneration()const{return connectionGeneration_;}
    WorkerTraceFreeze reason()const{return reason_;}
    std::uint64_t freeze100ns()const{return freeze100ns_;}
    std::uint32_t freezeOldUnderruns()const{return freezeOld_;}
    std::uint32_t freezeNewUnderruns()const{return freezeNew_;}
};
}
