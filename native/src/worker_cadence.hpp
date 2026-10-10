#pragma once
#include <cstdint>
#include <limits>

namespace ses {
// Worker-only monotonic scheduling. All times are 100ns units; a missed slot is
// skipped in constant time instead of triggering a sequence of catch-up polls.
class WorkerCadence {
    std::uint64_t deadline=0,last_now=0,period=0;
public:
    void reset(){deadline=last_now=period=0;}
    static bool validFrequency(std::uint64_t frequency){
        return frequency!=0&&frequency<=std::numeric_limits<std::uint64_t>::max()/10000000;
    }
    static bool qpcToHns(std::uint64_t counter,std::uint64_t frequency,std::uint64_t& hns){
        if(!validFrequency(frequency))return false;
        const auto seconds=counter/frequency;
        const auto fraction=(counter%frequency)*10000000/frequency;
        const auto maximum=std::numeric_limits<std::uint64_t>::max();
        if(seconds>(maximum-fraction)/10000000)return false;
        hns=seconds*10000000+fraction;
        return true;
    }
    bool delay(std::uint64_t now,unsigned milliseconds,std::uint64_t& hns){
        if(milliseconds==0||milliseconds>500||(period&&now<last_now))return false;
        const auto requested=static_cast<std::uint64_t>(milliseconds)*10000;
        auto remaining=requested;
        if(period==requested){
            remaining=now<deadline?deadline-now:period-(now-deadline)%period;
        }
        if(now>std::numeric_limits<std::uint64_t>::max()-remaining)return false;
        deadline=now+remaining;last_now=now;period=requested;
        hns=remaining;
        return true;
    }
};
}
