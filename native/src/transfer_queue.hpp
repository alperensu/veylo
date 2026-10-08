#pragma once
#include <array>
#include <atomic>
#include <cstdint>
namespace ses {
// One producer / one consumer. Voice older than 50ms is discarded even if a
// Discord consumer has been stopped for minutes. No allocation or mutex.
class TransferQueue {
    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    struct Block {std::array<float,480> samples{};uint64_t time=0;};
    std::array<Block,4> blocks{};
    std::atomic<uint64_t> write{0},read{0};
public:
    bool push(const float* input,uint64_t now){
        const auto w=write.load(std::memory_order_relaxed),r=read.load(std::memory_order_acquire);
        if(w-r>=4)return false;auto& block=blocks[w%4];
        for(unsigned i=0;i<480;++i)block.samples[i]=input[i];block.time=now;
        write.store(w+1,std::memory_order_release);return true;
    }
    bool take(float* output,uint64_t now){
        auto r=read.load(std::memory_order_relaxed);const auto w=write.load(std::memory_order_acquire);
        while(r<w&&now-blocks[r%4].time>50){++r;read.store(r,std::memory_order_release);}
        if(r==w)return false;for(unsigned i=0;i<480;++i)output[i]=blocks[r%4].samples[i];
        read.store(r+1,std::memory_order_release);return true;
    }
    void discard(){read.store(write.load(std::memory_order_acquire),std::memory_order_release);}
    unsigned frames()const{auto r=read.load(std::memory_order_acquire),w=write.load(std::memory_order_acquire);return unsigned(w-r)*480;}
};
}
