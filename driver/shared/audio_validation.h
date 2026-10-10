#pragma once
#include "ses_driver_protocol.h"
namespace ses_driver {
// KSDATAFORMAT is 64 bytes; WAVEFORMATEX is packed to 18 bytes on the wire.
struct PcmFormat {
    uint32_t format_bytes,tag,channels,rate,average_bytes,block_align,bits,extra_bytes;
};
inline bool validCaptureFormat(const PcmFormat& f) {
    if(f.format_bytes<82||f.format_bytes>104||f.channels!=1||f.rate!=SES_DRIVER_RATE||
       !(f.bits==16||f.bits==32)||f.block_align!=f.bits/8||
       f.average_bytes!=SES_DRIVER_RATE*f.block_align)return false;
    if(f.tag==1)return f.extra_bytes==0;
    return f.tag==0xfffe&&f.extra_bytes==22&&f.format_bytes>=104;
}
struct PcmAdvance {uint64_t bytes;uint32_t fraction;};
inline bool validNotificationBuffer(uint32_t bytes,uint32_t notifications,uint32_t align) {
    return (align==2||align==4)&&bytes&&(notifications==1||notifications==2)&&bytes%align==0&&
        bytes%notifications==0&&(bytes/notifications)%align==0&&
        bytes/notifications>=SES_DRIVER_RATE*align/1000&&
        (bytes/notifications)%(SES_DRIVER_RATE*align/1000)==0;
}
// Carry is a fractional frame in units of 1/10,000,000. Split seconds first
// so an hours-long suspend cannot overflow a 32-bit byte-rate product.
inline PcmAdvance advancePcm(uint64_t elapsed_hns,uint32_t block_align,uint32_t fraction) {
    const uint64_t numerator=(elapsed_hns%10000000)*SES_DRIVER_RATE+fraction;
    const uint64_t frames=(elapsed_hns/10000000)*SES_DRIVER_RATE+numerator/10000000;
    return {frames*block_align,static_cast<uint32_t>(numerator%10000000)};
}
inline uint64_t elapsedHns(uint64_t current,uint64_t previous,uint64_t carry=0) {
    if(current<previous)return 0;
    const uint64_t delta=current-previous,max=~uint64_t(0);
    return carry>max-delta?max:delta+carry;
}
// GetReadPacket reports the sampling time of the packet's FIRST frame.
// Use the full counter (not its 32-bit wire number) across packet-number wrap.
inline bool capturePacketStartHns(uint64_t completed_packets,uint64_t linear_bytes,
    uint64_t fractional_hns,uint64_t dma_hns,uint32_t packet_bytes,uint32_t byte_rate,
    uint64_t& start_hns) {
    const uint64_t max=~uint64_t(0),second=10000000;
    if(!completed_packets||!packet_bytes||!byte_rate||fractional_hns>=second||
       completed_packets-1>max/packet_bytes)return false;
    const uint64_t first_byte=(completed_packets-1)*packet_bytes;
    if(linear_bytes<first_byte)return false;
    const uint64_t distance=linear_bytes-first_byte,whole=distance/byte_rate;
    if(whole>max/second)return false;
    const uint64_t remainder=(distance%byte_rate)*second/byte_rate;
    const uint64_t base=whole*second;
    if(remainder>max-base||fractional_hns>max-base-remainder)return false;
    const uint64_t age=base+remainder+fractional_hns;
    if(age>dma_hns)return false;
    start_hns=dma_hns-age;return true;
}
inline bool hnsToQpc(uint64_t hns,uint64_t frequency,uint64_t& qpc) {
    const uint64_t max=~uint64_t(0),second=10000000;
    if(!frequency||frequency>max/second||hns/second>max/frequency)return false;
    const uint64_t whole=(hns/second)*frequency;
    const uint64_t part=(hns%second)*frequency/second;
    if(part>max-whole)return false;
    qpc=whole+part;return true;
}
}
