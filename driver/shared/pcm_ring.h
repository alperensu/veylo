#pragma once
#include "ses_driver_protocol.h"
/* Serialized by the driver's spinlock (or the test owner). Bounded storage,
   integer-only resampling. A missing producer always clears pending audio. */
namespace ses_driver {
struct PcmRing {
    int32_t samples[SES_DRIVER_CAPACITY]{};
    uint64_t read=0,write=0,last_ms=0,sequence=0,received=0,silence=0;
    uint32_t fraction=0,underruns=0,overruns=0;
    int32_t drift_ppm=0;
    bool attached=false,primed=false;
    void discard(){read=write;fraction=0;primed=false;drift_ppm=0;}
    void disconnect(){attached=false;discard();}
    bool connect(const SesDriverHello& h,uint64_t now){
        if(h.version!=SES_DRIVER_PROTOCOL||h.size!=sizeof(h)||h.rate!=48000||h.channels!=1||h.bits!=32||h.frames!=480)return false;
        discard();attached=true;last_ms=now;sequence=0;return true;
    }
    uint32_t queued()const{return static_cast<uint32_t>(write-read);}
    bool push(const SesDriverPacket& p,uint64_t now){
        if(!attached||p.version!=SES_DRIVER_PROTOCOL||p.size!=sizeof(p)||p.frames!=480||p.reserved||p.sequence!=sequence)return false;
        if(now-last_ms>SES_DRIVER_TIMEOUT_MS)discard();
        if(queued()+480>SES_DRIVER_CAPACITY){++overruns;return false;}
        for(uint32_t i=0;i<480;++i)samples[(write+i)%SES_DRIVER_CAPACITY]=p.pcm[i];
        write+=480;received+=480;++sequence;last_ms=now;return true;
    }
    void pull(void* buffer,uint32_t frames,uint32_t bits,uint64_t now){
        auto* pcm16=static_cast<int16_t*>(buffer);auto* pcm32=static_cast<int32_t*>(buffer);
        if(!attached||now-last_ms>SES_DRIVER_TIMEOUT_MS)discard();
        if(!primed&&queued()>=SES_DRIVER_TARGET+1)primed=true;
        int64_t correction=(static_cast<int64_t>(queued())-SES_DRIVER_TARGET)*65536/(SES_DRIVER_TARGET*200);
        if(correction>328)correction=328;if(correction< -328)correction= -328;
        const uint32_t step=static_cast<uint32_t>(65536+correction);drift_ppm=static_cast<int32_t>(correction*1000000/65536);
        for(uint32_t i=0;i<frames;++i){
            int32_t value=0;
            if(primed&&queued()>1){
                const int64_t a=samples[read%SES_DRIVER_CAPACITY],b=samples[(read+1)%SES_DRIVER_CAPACITY];
                value=static_cast<int32_t>(a+(b-a)*fraction/65536);
                fraction+=step;read+=fraction/65536;fraction%=65536;
            }else{if(primed){++underruns;discard();}++silence;}
            if(bits==16)pcm16[i]=static_cast<int16_t>(value/65536);else pcm32[i]=value;
        }
    }
    SesDriverStatus status()const{return {SES_DRIVER_PROTOCOL,sizeof(SesDriverStatus),attached?1u:0u,queued(),received,silence,underruns,overruns,drift_ppm,0};}
};
}
