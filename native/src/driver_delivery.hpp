#pragma once
#include "driver_io.hpp"

namespace ses {
enum class DriverDeliveryAttempt { Empty, Written, Failed };
enum class DriverDeliveryResult { Complete, WriteFailed, StatusFailed };

// Worker-owned, single source owner only. Capture/discard can reduce occupancy;
// only this worker's successful WRITE can increase it. A validated queue count
// plus later successful WRITEs is therefore an upper bound, never a new STATUS.
class DriverDelivery {
    uint32_t upperBound_=0;
    bool valid_=false;
public:
    void reset(){upperBound_=0;valid_=false;}
    bool observe(const SesDriverStatus& info){
        reset();
        if(driverStatusError(info)!=ERROR_SUCCESS)return false;
        upperBound_=info.queued_frames;valid_=true;return true;
    }
    bool gateOpen()const{return valid_&&upperBound_<SES_DRIVER_TARGET*2+1;}
    bool valid()const{return valid_;}
    uint32_t upperBound()const{return upperBound_;}

    // Deliver(gate, freshStatus) expires/takes at most one upstream packet and
    // returns Written only after a successful WRITE. Refresh validates STATUS
    // and freezes first-underrun evidence before publishing or subsequent work.
    // Failure abandons the bound along with the caller's connection error path.
    template<class Deliver,class Refresh> DriverDeliveryResult iteration(Deliver&& deliver,Refresh&& refresh){
        bool written=false;
        if(gateOpen()){
            const auto attempt=deliver(true,false);
            if(attempt==DriverDeliveryAttempt::Failed){reset();return DriverDeliveryResult::WriteFailed;}
            if(attempt==DriverDeliveryAttempt::Written){upperBound_+=SES_DRIVER_FRAMES;written=true;}
        }
        SesDriverStatus info{};
        if(!refresh(info)||!observe(info)){reset();return DriverDeliveryResult::StatusFailed;}
        if(!written){
            const auto attempt=deliver(gateOpen(),true);
            if(attempt==DriverDeliveryAttempt::Failed){reset();return DriverDeliveryResult::WriteFailed;}
            if(attempt==DriverDeliveryAttempt::Written)upperBound_+=SES_DRIVER_FRAMES;
        }
        return DriverDeliveryResult::Complete;
    }
};
}
