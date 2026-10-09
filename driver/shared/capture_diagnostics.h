#pragma once
#include "ses_driver_protocol.h"
namespace ses_driver {
inline constexpr SesDriverDiagnostics initialCaptureDiagnostics() {
    SesDriverDiagnostics data{};
    data.version=SES_DRIVER_DIAGNOSTICS_VERSION;data.size=sizeof(data);
    return data;
}
// Caller serializes events with the existing bridge spinlock. Capture calls
// themselves are serialized by the stream's position lock. No audio is stored.
class CaptureDiagnostics {
    SesDriverDiagnostics data_=initialCaptureDiagnostics();
    uint64_t generation_=0;
    uint32_t capture_frames_=0;
    bool capture_active_=false,has_write_=false;
    bool current(uint64_t token,bool attached)const {
        return attached&&capture_active_&&token&&token==generation_;
    }
public:
    constexpr CaptureDiagnostics()=default;
    static uint64_t saturatingAdd(uint64_t value,uint64_t amount) {
        const uint64_t maximum=~uint64_t(0);
        return amount>maximum-value?maximum:value+amount;
    }
    static uint64_t elapsed(uint64_t now,uint64_t before) {
        return now>=before?now-before:0;
    }
    void reset() {
        data_=initialCaptureDiagnostics();
        // Zero is the inactive token. A full 64-bit wrap needs more reconnects
        // than can occur during a bounded capture call; no retry loop is used.
        ++generation_;if(!generation_)generation_=1;
        capture_frames_=0;capture_active_=false;has_write_=false;
    }
    void successfulWrite(bool attached,uint64_t tick_hns) {
        if(!attached)return;
        const uint64_t gap=has_write_?elapsed(tick_hns,data_.last_successful_write_tick_hns):0;
        data_.last_successful_write_tick_hns=tick_hns;data_.last_successful_write_gap_hns=gap;
        if(gap>data_.max_successful_write_gap_hns)data_.max_successful_write_gap_hns=gap;
        has_write_=true;
    }
    uint64_t beginCapture(bool attached,uint32_t frames,uint32_t queued,uint64_t tick_hns) {
        capture_active_=attached&&frames!=0;
        if(!capture_active_)return 0;
        capture_frames_=frames;
        data_.capture_calls=saturatingAdd(data_.capture_calls,1);
        data_.total_requested_frames=saturatingAdd(data_.total_requested_frames,frames);
        if(frames>data_.max_capture_frames)data_.max_capture_frames=frames;
        data_.last_capture_frames=frames;data_.last_capture_tick_hns=tick_hns;
        data_.last_capture_queued_before=queued;data_.last_capture_queued_after=queued;
        return generation_;
    }
    void pulled(uint64_t token,bool attached,bool primed_before,uint32_t chunk_frames,
                uint32_t remaining_frames,uint64_t tick_hns,
                const SesDriverStatus& before,const SesDriverStatus& after) {
        if(!current(token,attached))return;
        if(chunk_frames>data_.max_pull_chunk_frames)data_.max_pull_chunk_frames=chunk_frames;
        if(data_.first_underrun_present||!primed_before||after.underruns==before.underruns)return;
        data_.first_underrun_present=1;
        data_.first_underrun_queued_before=before.queued_frames;
        data_.first_underrun_chunk_frames=chunk_frames;
        data_.first_underrun_remaining_frames=remaining_frames;
        data_.first_underrun_capture_frames=capture_frames_;
        data_.first_underrun_old_count=before.underruns;data_.first_underrun_new_count=after.underruns;
        data_.first_underrun_tick_hns=tick_hns;
        data_.first_underrun_since_successful_write_hns=has_write_?elapsed(tick_hns,data_.last_successful_write_tick_hns):0;
        data_.first_underrun_successful_write_tick_hns=data_.last_successful_write_tick_hns;
        data_.first_underrun_received_frames=after.received_frames;
        data_.first_underrun_silence_before=before.silence_frames;data_.first_underrun_silence_after=after.silence_frames;
    }
    void endCapture(uint64_t token,bool attached,uint32_t queued) {
        if(!current(token,attached))return;
        data_.last_capture_queued_after=queued;capture_active_=false;
    }
    SesDriverDiagnostics snapshot()const{return data_;}
};
inline bool validCaptureDiagnostics(const SesDriverDiagnostics& data) {
    return data.version==SES_DRIVER_DIAGNOSTICS_VERSION&&data.size==sizeof(data)&&
        data.reserved0==0&&data.reserved1==0;
}
}
