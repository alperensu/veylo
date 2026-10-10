#pragma once
#include "ses_driver_protocol.h"

namespace ses_driver {
// One incomplete packet plus eight complete packets in caller-owned nonpaged
// storage. The stream's position lock serializes every operation. Only the
// caller of GetReadPacket publishes a complete packet into the WaveRT buffer;
// the producer must never write that buffer while the OS is reading it.
class CapturePackets {
public:
    static constexpr uint32_t Capacity=8;
    static constexpr uint32_t StorageSlots=Capacity+1;
    static constexpr uint32_t MaxPacketBytes=19200;
    struct WriteSpan {unsigned char* data;uint32_t bytes;};
    struct Packet {const unsigned char* data;uint64_t number;uint64_t dropped;bool moreData;uint64_t startHns;};
private:
    unsigned char* storage_=nullptr;
    uint32_t packet_bytes_=0,alignment_=0;
    uint64_t linear_bytes_=0,next_unread_=0,dropped_=0,pending_dropped_=0;
    uint64_t start_hns_[StorageSlots]{};
    bool has_start_[StorageSlots]{};
    static uint64_t add(uint64_t value,uint64_t amount) {
        const uint64_t maximum=~uint64_t(0);
        return amount>maximum-value?maximum:value+amount;
    }
    void drop(uint64_t count) {
        dropped_=add(dropped_,count);pending_dropped_=add(pending_dropped_,count);
    }
    void clearStorage() {
        if(storage_)for(uint32_t i=0;i<packet_bytes_*StorageSlots;++i)storage_[i]=0;
        for(uint32_t i=0;i<StorageSlots;++i){start_hns_[i]=0;has_start_[i]=false;}
    }
public:
    // Packet periods are whole milliseconds, bounded to 100 ms. Validation
    // precedes multiplication or writes, so failed configuration cannot touch
    // caller storage. It leaves any previous valid configuration unchanged.
    bool configure(void* buffer,uint32_t buffer_bytes,uint32_t packet_bytes,uint32_t alignment) {
        if(!buffer||(alignment!=2&&alignment!=4)||!packet_bytes||
           packet_bytes>MaxPacketBytes||packet_bytes>SES_DRIVER_RATE*alignment/10||
           packet_bytes%(SES_DRIVER_RATE*alignment/1000)||
           buffer_bytes<packet_bytes*StorageSlots)return false;
        storage_=static_cast<unsigned char*>(buffer);
        packet_bytes_=packet_bytes;alignment_=alignment;reset();return true;
    }
    void reset() {
        linear_bytes_=0;next_unread_=0;dropped_=0;pending_dropped_=0;clearStorage();
    }
    uint32_t packetBytes()const{return packet_bytes_;}
    uint64_t linearBytes()const{return linear_bytes_;}
    uint64_t completedPackets()const{return packet_bytes_?linear_bytes_/packet_bytes_:0;}
    uint64_t droppedPackets()const{return dropped_;}
    WriteSpan writeSpan()const {
        if(!storage_||!packet_bytes_)return {nullptr,0};
        const uint32_t offset=static_cast<uint32_t>(linear_bytes_%packet_bytes_);
        const uint32_t slot=static_cast<uint32_t>(completedPackets()%StorageSlots);
        return {storage_+slot*packet_bytes_+offset,packet_bytes_-offset};
    }
    // Commit only bytes actually initialized through the current write span.
    // Advancing farther would publish uninitialized or overwritten PCM.
    bool commit(uint32_t bytes,uint64_t first_sample_hns=0) {
        const auto span=writeSpan();
        if(!span.data||!bytes||bytes>span.bytes||bytes%alignment_||
           bytes>~uint64_t(0)-linear_bytes_)return false;
        const uint32_t slot=static_cast<uint32_t>(completedPackets()%StorageSlots);
        if(!has_start_[slot]||linear_bytes_%packet_bytes_==0){start_hns_[slot]=first_sample_hns;has_start_[slot]=true;}
        linear_bytes_+=bytes;
        const uint64_t completed=completedPackets();
        const uint64_t oldest=completed>Capacity?completed-Capacity:0;
        if(next_unread_<oldest){drop(oldest-next_unread_);next_unread_=oldest;}
        return true;
    }
    Packet peek()const {
        const uint64_t completed=completedPackets();
        if(!storage_||next_unread_>=completed)return {nullptr,0,0,false,0};
        const uint32_t slot=static_cast<uint32_t>(next_unread_%StorageSlots);
        return {storage_+slot*packet_bytes_,next_unread_,pending_dropped_,next_unread_+1<completed,start_hns_[slot]};
    }
    // The caller validates timestamp metadata and copies peek().data to DMA
    // before consuming, while still holding the same position lock.
    bool consume(uint64_t number) {
        if(!storage_||number!=next_unread_||number>=completedPackets())return false;
        ++next_unread_;pending_dropped_=0;return true;
    }
    // Producer session changes invalidate pending complete AND partial PCM,
    // preserving the device timeline so any lost interval remains observable.
    void discard() {
        if(!storage_)return;
        const uint64_t completed=completedPackets();
        drop(completed-next_unread_);next_unread_=completed;clearStorage();
    }
    // Suspends exceeding the bounded write budget advance the real timeline
    // without an elapsed-time loop. Old PCM becomes unavailable; a partly
    // skipped assembly packet has a zero prefix. Packet-number gaps and the
    // cumulative drop counter expose the loss instead of fabricating delivery.
    bool skipTo(uint64_t linear_bytes) {
        if(!storage_||linear_bytes<linear_bytes_||linear_bytes%alignment_)return false;
        if(linear_bytes==linear_bytes_)return true;
        const uint64_t completed=linear_bytes/packet_bytes_;
        drop(completed-next_unread_);
        linear_bytes_=linear_bytes;next_unread_=completed;clearStorage();return true;
    }
};
}
