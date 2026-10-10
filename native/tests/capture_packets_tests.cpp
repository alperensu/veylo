#include "../../driver/shared/capture_packets.h"
#include "../../driver/shared/audio_validation.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

static unsigned checks=0;
static void check(bool ok,const char* name) {
    ++checks;if(!ok){std::fprintf(stderr,"FAIL %s\n",name);std::exit(1);}
}
using ses_driver::CapturePackets;
static void produce(CapturePackets& packets,uint32_t bytes,unsigned char value) {
    while(bytes) {
        const auto span=packets.writeSpan();
        const uint32_t run=bytes<span.bytes?bytes:span.bytes;
        check(span.data&&run,"Producer has a bounded assembly destination");
        std::memset(span.data,value,run);
        check(packets.commit(run),"Producer commits initialized frame-aligned PCM");bytes-=run;
    }
}
static bool all(const unsigned char* data,uint32_t bytes,unsigned char value) {
    for(uint32_t i=0;i<bytes;++i)if(data[i]!=value)return false;
    return true;
}
static void validation() {
    CapturePackets packets;
    std::array<unsigned char,CapturePackets::MaxPacketBytes*CapturePackets::StorageSlots> storage;
    storage.fill(0x5a);
    check(!packets.peek().data&&!packets.writeSpan().data,"Unconfigured queue exposes no PCM");
    check(!packets.commit(4)&&!packets.consume(0)&&!packets.skipTo(4),"Unconfigured mutations fail closed");
    check(!packets.configure(nullptr,sizeof(storage),1920,4),"Null storage rejected");
    for(uint32_t align:{0u,1u,3u,8u})
        check(!packets.configure(storage.data(),sizeof(storage),1920,align),"Unsupported alignment rejected");
    for(uint32_t bytes:{0u,4u,190u,191u,193u,19201u,0xffffffffu})
        check(!packets.configure(storage.data(),sizeof(storage),bytes,4),"Invalid or oversized packet rejected before writes");
    check(!packets.configure(storage.data(),17279,1920,4),"Storage needs eight complete packets and one assembly packet");
    check(all(storage.data(),sizeof(storage),0x5a),"Rejected configuration cannot write caller storage");
    for(uint32_t align:{2u,4u})for(uint32_t period=1;period<=100;++period) {
        const uint32_t bytes=48*align*period;
        check(packets.configure(storage.data(),sizeof(storage),bytes,align),"Whole-millisecond PCM16/PCM32 period accepted");
        check(packets.packetBytes()==bytes&&packets.linearBytes()==0,"Configuration resets stream timeline");
    }
    check(!packets.configure(storage.data(),sizeof(storage),9696,2),"PCM16 periods exceeding 100 ms rejected");
    check(!packets.commit(0)&&!packets.commit(1)&&!packets.commit(19204),"Invalid commits cannot publish PCM");
    check(packets.linearBytes()==0,"Rejected commits preserve timeline");
}
static void coalescedAndPartialOverwrite(uint32_t align) {
    const uint32_t bytes=480*align;
    std::array<unsigned char,1920*CapturePackets::StorageSlots> storage{};
    std::array<unsigned char,3840> dma{};
    CapturePackets packets;
    check(packets.configure(storage.data(),sizeof(storage),bytes,align),"Configure real 10 ms packet queue");
    produce(packets,bytes,0x31);produce(packets,bytes,0x52);produce(packets,48*align,0x73);
    check(packets.completedPackets()==2,"Coalesced notification represents two complete source packets");
    auto packet=packets.peek();
    check(packet.data&&packet.number==0&&packet.moreData&&packet.dropped==0,"Oldest complete packet is available before latest");
    check(all(packet.data,bytes,0x31),"Third packet's partial write cannot corrupt retained first packet");
    std::memcpy(dma.data(),packet.data,bytes);
    check(packets.consume(packet.number),"First copied packet acknowledged");
    produce(packets,bytes-48*align,0x73);
    check(all(dma.data(),bytes,0x31),"Producer never mutates published DMA while OS reads");
    packet=packets.peek();
    check(packet.data&&packet.number==1&&packet.moreData&&all(packet.data,bytes,0x52),"Second complete packet retained with its original PCM");
    std::memcpy(dma.data()+bytes,packet.data,bytes);check(packets.consume(packet.number),"Second packet acknowledged");
    packet=packets.peek();
    check(packet.data&&packet.number==2&&!packet.moreData&&all(packet.data,bytes,0x73),"Third packet completes without duplicate or omission");
    std::memcpy(dma.data(),packet.data,bytes);check(packets.consume(packet.number),"Reused DMA slot published only after prior read");
    check(!packets.peek().data&&packets.droppedPackets()==0,"Drained queue is empty with no hidden drop");
    check(!packets.consume(2)&&!packets.consume(3),"Already consumed and incomplete packets cannot be acknowledged");
}
static void overflowAndFailedRead() {
    constexpr uint32_t bytes=1920;
    std::array<unsigned char,bytes*CapturePackets::StorageSlots> storage{};
    CapturePackets packets;check(packets.configure(storage.data(),sizeof(storage),bytes,4),"Configure bounded-overflow fixture");
    for(uint32_t i=0;i<11;++i)produce(packets,bytes,static_cast<unsigned char>(i+1));
    produce(packets,192,0x77);
    check(packets.completedPackets()==11&&packets.droppedPackets()==3,"Overflow drops exactly oldest complete packets");
    const auto before=packets.peek();const auto repeated=packets.peek();
    check(before.data&&before.number==3&&before.dropped==3&&before.moreData,"Overflow keeps eight newest complete packets");
    check(before.number==repeated.number&&before.dropped==repeated.dropped&&before.data==repeated.data,"Failed timestamp or copy leaves oldest packet available");
    check(!packets.consume(4)&&packets.peek().number==3,"Out-of-order acknowledgement cannot discard pending PCM");
    for(uint64_t i=3;i<11;++i) {
        const auto packet=packets.peek();
        check(packet.data&&packet.number==i&&all(packet.data,bytes,static_cast<unsigned char>(i+1)),"Circular retention preserves sequence and payload after overflow");
        check(packet.dropped==(i==3?3u:0u),"Overflow report is retained until first successful read");
        check(packet.moreData==(i+1<11),"MoreData describes complete remaining packets only");
        check(packets.consume(i),"Retained packet acknowledged in source order");
    }
    check(!packets.peek().data,"Partial assembly alone is never advertised");
}
static void suspendResetAndWrap() {
    constexpr uint32_t bytes=1920;
    std::array<unsigned char,bytes*CapturePackets::StorageSlots> storage{};
    CapturePackets packets;check(packets.configure(storage.data(),sizeof(storage),bytes,4),"Configure suspend fixture");
    produce(packets,bytes*2+192,0x5a);
    check(!packets.skipTo(bytes)&&!packets.skipTo(bytes*3+1),"Backward and non-frame-aligned skips rejected");
    const uint64_t jump=(uint64_t(1)<<32)+17;
    check(packets.skipTo(jump*bytes+192),"Long suspend advances beyond 32-bit packet wrap without elapsed-time work");
    check(packets.completedPackets()==jump&&!packets.peek().data,"Suspend discards all queued pre-suspend PCM");
    check(packets.droppedPackets()==jump&&all(storage.data(),sizeof(storage),0),"Suspend clears old voice and accounts skipped packet numbers");
    produce(packets,bytes-192,0x33);
    auto packet=packets.peek();
    check(packet.data&&packet.number==jump&&packet.dropped==jump,"Full-width packet ordinal survives wire-number wrap");
    check(all(packet.data,192,0)&&all(packet.data+192,bytes-192,0x33),"Skipped partial packet never exposes stale prefix");
    uint64_t stamp=0;
    const uint64_t dmaHns=packets.linearBytes()/192000*10000000+(packets.linearBytes()%192000)*10000000/192000+1000000;
    check(ses_driver::capturePacketStartHns(packet.number+1,packets.linearBytes(),0,dmaHns,bytes,192000,stamp),"Retained packet has a valid first-sample timestamp across wrap");
    check(dmaHns-stamp==100000,"Timestamp refers to first frame, one complete packet before DMA clock");
    check(packets.consume(packet.number),"Post-suspend packet acknowledged");
    packets.reset();
    check(packets.completedPackets()==0&&packets.linearBytes()==0&&packets.droppedPackets()==0&&!packets.peek().data,"STOP resets sequence, telemetry and pending delivery");
    check(all(storage.data(),sizeof(storage),0),"STOP clears retained PCM");
    produce(packets,bytes,0x11);check(packets.peek().number==0,"Restart begins with source packet zero");
    const uint64_t maximumAligned=std::numeric_limits<uint64_t>::max()-3;
    check(packets.skipTo(maximumAligned),"Largest aligned byte position accepted without overflow");
    const auto end=packets.writeSpan();
    check(end.data&&end.bytes>=4&&!packets.commit(4)&&packets.linearBytes()==maximumAligned,"Byte counter overflow cannot wrap stream position");
}
static void longCadence() {
    constexpr uint32_t bytes=1920;
    std::array<unsigned char,bytes*CapturePackets::StorageSlots> storage{};
    std::array<unsigned char,bytes*2> dma{};
    CapturePackets packets;check(packets.configure(storage.data(),sizeof(storage),bytes,4),"Configure cadence fixture");
    uint64_t expected=0;
    // Every fourth wake intentionally coalesces 20 ms; a 1 ms partial write
    // follows it before the OS drains. Distinct packet PCM catches wrong-slot
    // publication independently of number/timestamp checks.
    for(uint32_t wake=0;wake<2000;++wake) {
        const uint32_t count=wake%4==0?2u:1u;
        const uint64_t first=packets.completedPackets();
        for(uint32_t i=0;i<count;++i) {
            const uint32_t remainder=packets.writeSpan().bytes;
            produce(packets,remainder,static_cast<unsigned char>((first+i)%251+1));
        }
        produce(packets,192,static_cast<unsigned char>(packets.completedPackets()%251+1));
        for(auto packet=packets.peek();packet.data;packet=packets.peek()) {
            check(packet.number==expected&&packet.dropped==0,"Repeated coalescing preserves contiguous full packet sequence");
            check(all(packet.data,bytes,static_cast<unsigned char>(expected%251+1)),"Repeated coalescing preserves exact complete packet PCM");
            std::memcpy(dma.data()+(packet.number%2)*bytes,packet.data,bytes);
            check(packets.consume(packet.number),"Repeated coalesced packet acknowledged");++expected;
        }
    }
    check(expected==2500&&packets.droppedPackets()==0,"Long bounded cadence drains every produced complete packet");
}
static void savedTimestampAndProducerDiscard() {
    constexpr uint32_t bytes=1920;
    std::array<unsigned char,bytes*CapturePackets::StorageSlots> storage{};
    CapturePackets packets;check(packets.configure(storage.data(),sizeof(storage),bytes,4),"Configure retained timestamp fixture");
    auto span=packets.writeSpan();std::memset(span.data,0x41,192);
    check(packets.commit(192,1000000),"First partial PCM saves its sampling instant");
    span=packets.writeSpan();std::memset(span.data,0x42,bytes-192);
    check(packets.commit(bytes-192,11000000),"A resumed assembly completes without restamping its first sample");
    auto packet=packets.peek();
    check(packet.startHns==1000000&&packet.number==0,"PAUSE RUN cannot move a retained first sample by the pause duration");
    check(packets.peek().startHns==1000000,"Repeated peek preserves immutable packet metadata");
    produce(packets,192,0x61);
    packets.discard();
    check(!packets.peek().data&&packets.linearBytes()==bytes+192&&packets.completedPackets()==1,
          "Producer disconnect, replacement or timeout discards unread PCM without resetting the device timeline");
    check(all(storage.data(),sizeof(storage),0),"Producer invalidation clears both completed and partial old voice");
    span=packets.writeSpan();std::memset(span.data,0x52,bytes-192);
    check(packets.commit(bytes-192,12000000),"Replacement source can finish the zero-prefixed partial packet");
    packet=packets.peek();
    check(packet.number==1&&packet.startHns==12000000&&packet.dropped==1,
          "Replacement voice carries only its new timing and keeps the discarded packet gap visible");
    check(all(packet.data,192,0)&&all(packet.data+192,bytes-192,0x52),"Replacement assembly contains no old voice");
}
int main() {
    validation();coalescedAndPartialOverwrite(2);coalescedAndPartialOverwrite(4);
    overflowAndFailedRead();suspendResetAndWrap();longCadence();savedTimestampAndProducerDiscard();
    std::printf("%u capture packet retention checks, zero failures. Portable tests do not claim a live WaveRT run.\n",checks);
    return 0;
}
