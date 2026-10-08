#include "../../driver/shared/pcm_ring.h"
#include "../src/transfer_queue.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <thread>
static unsigned checks=0;
static void check(bool x,const char* msg){++checks;if(!x){std::fprintf(stderr,"%s\n",msg);std::exit(1);}}
int main(){
    ses::TransferQueue transfer;std::array<float,480> voice{},copied{};voice.fill(.3f);
    check(transfer.push(voice.data(),0),"Queue voice");check(!transfer.take(copied.data(),60000),"Stopped consumer cannot replay one-minute-old voice");
    for(unsigned i=0;i<4;++i)check(transfer.push(voice.data(),60000),"Fixed queue capacity");check(!transfer.push(voice.data(),60000),"Queue overflow is bounded");
    check(transfer.take(copied.data(),60040)&&copied[0]==.3f,"Fresh voice delivered");transfer.discard();check(!transfer.take(copied.data(),60040),"Reconnection discards queued voice");
    ses::TransferQueue concurrent;std::atomic<bool> torn{false};
    std::thread producer([&]{std::array<float,480> block{};for(unsigned i=1;i<=10000;++i){block.fill(float(i));while(!concurrent.push(block.data(),0))std::this_thread::yield();}});
    for(unsigned i=1;i<=10000;++i){while(!concurrent.take(copied.data(),0))std::this_thread::yield();for(auto value:copied)if(value!=float(i))torn=true;}
    producer.join();check(!torn&&concurrent.frames()==0,"Concurrent SPSC blocks are ordered and never torn");
    ses_driver::PcmRing ring;SesDriverHello hello{1,sizeof(hello),48000,1,32,480};
    std::array<int32_t,480> out;out.fill(7);ring.pull(out.data(),480,32,0);check(out[0]==0&&out.back()==0,"No producer gives silence");
    auto bad=hello;bad.version=2;check(!ring.connect(bad,0),"Reject incompatible version");bad=hello;bad.rate=44100;check(!ring.connect(bad,0),"Reject rate");
    check(ring.connect(hello,0),"Connect");SesDriverPacket p{1,sizeof(p),480,0,0,{}};for(auto& x:p.pcm)x=1073741824;
    bad=hello;bad.size=0;check(!ring.connect(bad,0),"Reject size");auto corrupt=p;corrupt.reserved=1;check(!ring.push(corrupt,0),"Reject reserved");
    check(ring.push(p,0),"Push");check(!ring.push(p,0),"Reject replay");++p.sequence;check(ring.push(p,10),"Second packet");ring.pull(out.data(),480,32,10);check(out[0]==1073741824,"PCM32 preserved");
    std::array<int16_t,480> narrow{};ring.pull(narrow.data(),480,16,20);check(narrow[0]==16384,"PCM16 conversion");
    ring.pull(out.data(),480,32,120);check(out[0]==0&&out.back()==0&&ring.queued()==0,"Timeout purges stale voice");
    ring.disconnect();check(!ring.push(p,130),"Disconnected rejects writes");check(ring.connect(hello,130),"Reconnect");p.sequence=0;check(ring.push(p,130),"New sequence starts at zero");ring.disconnect();ring.pull(out.data(),480,32,130);check(out[0]==0,"Disconnect silence");
    ring.connect(hello,0);p.sequence=0;for(int i=0;i<8;i++){check(ring.push(p,0),"Bounded ring accepts capacity");++p.sequence;}check(!ring.push(p,0)&&ring.overruns==1,"Reject overflow without overwriting unread audio");
    ring.disconnect();ring.connect(hello,0);p.sequence=0;uint64_t time=0; // one hour with +/- clock changes, starvation and full-scale samples
    for(unsigned tick=0;tick<360000;++tick){
        for(unsigned i=0;i<480;++i)p.pcm[i]=(i&1)?std::numeric_limits<int32_t>::min():std::numeric_limits<int32_t>::max();
        if(ring.queued()<1440){if(ring.push(p,time))++p.sequence;}
        ring.pull(out.data(),480,32,time);time+=10;
        if(tick%10000==0){time+=101;ring.pull(out.data(),480,32,time);check(out[0]==0,"Long gaps mute old audio");}
        if(ring.queued()>SES_DRIVER_CAPACITY)std::abort();
    }
    check(ring.received>100000000,"One hour simulation processed");std::printf("%u transport checks passed (one-hour deterministic simulation, not live driver QA)\n",checks);
}

