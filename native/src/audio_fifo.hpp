#pragma once
#include "clock.hpp"
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>

namespace ses {
// One capture producer / one render consumer; storage and controller are bounded.
class AudioFifo {
    static constexpr unsigned capacity=8192;
    std::array<float,capacity> samples_{};
    std::atomic<uint64_t> write_{0},read_{0};
    double fraction_=0;
    unsigned pendingAdvance_=0;
    float previous_=0;
    bool primed_=false;
    ClockController clock_;
public:
    struct ReadResult {
        unsigned rendered=0,startingFill=0,remainingFill=0,underflowAvailable=0,underflowRemaining=0,refreshedWrites=0;
        bool underrun=false,waiting=false;
        double ratio=1;
    };
    // Owner resets only after both callbacks have stopped.
    void reset(){write_=0;read_=0;fraction_=0;pendingAdvance_=0;previous_=0;primed_=false;clock_.reset();}
    bool write(const float* source,unsigned count){
        const auto w=write_.load(std::memory_order_relaxed),r=read_.load(std::memory_order_acquire);
        if(count>=capacity||w-r+count>=capacity)return false;
        for(unsigned i=0;i<count;++i)samples_[(w+i)%capacity]=source[i];
        write_.store(w+count,std::memory_order_release);return true;
    }
    // WASAPI supplies a callback-sized demand, while capture publishes 480-frame
    // packets. Interpret bufferFrames as the FIFO's nominal upper phase budget:
    // half a packet accounts for quantization; the remainder stays AFTER render.
    // Previously a fixed pre-render target could be smaller than the callback.
    // Servo error uses capture-packet units, independent of callback size.
    ReadResult readBuffered(float* destination,unsigned frames,unsigned bufferFrames){
        const unsigned postReserve=bufferFrames>240?bufferFrames-240:0;
        const uint64_t wanted=uint64_t(frames)+postReserve;
        const unsigned target=unsigned(std::min<uint64_t>(wanted,UINT32_MAX));
        return read(destination,frames,target,480);
    }
    ReadResult read(float* destination,unsigned frames,unsigned target,unsigned normalization=0){
        std::fill_n(destination,frames,0.f);
        auto r=read_.load(std::memory_order_relaxed),w=write_.load(std::memory_order_acquire);
        ReadResult result;result.startingFill=unsigned(w-r);result.remainingFill=result.startingFill;
        // Priming covers the negotiated callback; larger periods are diagnosed.
        const auto prime=std::max<uint64_t>(target,uint64_t(std::ceil(frames*1.001))+1);
        if(!primed_){if(w-r<prime){result.waiting=true;return result;}primed_=true;}
        result.ratio=clock_.ratio(double(w-r),target,frames,normalization);
        const auto available=[&]{if(r>=w){const auto fresh=write_.load(std::memory_order_acquire);if(fresh!=w){w=fresh;++result.refreshedWrites;}}return r<w;};
        for(unsigned i=0;i<frames;++i){
            // Consume the preceding output's advance only when source samples
            // exist. Copy history before releasing cells to the producer.
            bool missing=false;
            while(pendingAdvance_){
                if(!available()){missing=true;break;}
                previous_=samples_[r%capacity];++r;--pendingAdvance_;
            }
            if(!missing&&!available())missing=true;
            if(missing){result.underrun=true;result.underflowAvailable=unsigned(w-r);result.underflowRemaining=frames-i;primed_=false;fraction_=0;pendingAdvance_=0;previous_=0;break;}
            // Causal interpolation adds exactly one sample of alignment. It
            // uses real history/current data, not a repeated last-sample fallback.
            const float current=samples_[r%capacity];
            destination[i]=float(previous_+(current-previous_)*fraction_);
            fraction_+=result.ratio;pendingAdvance_=unsigned(fraction_);fraction_-=pendingAdvance_;++result.rendered;
        }
        read_.store(r,std::memory_order_release);result.remainingFill=unsigned(w-r);return result;
    }
};
}
