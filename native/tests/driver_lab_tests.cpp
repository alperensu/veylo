#include <windows.h>
#include <cstdio>
#include <cstring>
#include <array>
#include "../../driver/shared/ses_driver_protocol.h"
// Run ONLY on an isolated Windows driver lab, never the daily gaming machine.
int main(int argc,char** argv){
    if(argc!=2||std::strcmp(argv[1],"--isolated-lab")){std::puts("Requires --isolated-lab on a dedicated Windows VM/test machine.");return 2;}
    HANDLE first=CreateFileW(SES_DRIVER_PATH,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,0,nullptr);
    if(first==INVALID_HANDLE_VALUE){std::printf("Driver unavailable (%lu)\n",GetLastError());return 3;}
    unsigned failures=0,checks=0;DWORD bytes=0;SesDriverHello hello{1,sizeof(hello),48000,1,32,480};SesDriverStatus status{};SesDriverPacket packet{1,sizeof(packet),480,0,0,{}};
    auto check=[&](bool ok,const char* name){++checks;if(!ok){++failures;std::printf("FAIL %s (%lu)\n",name,GetLastError());}};
    SesDriverDiagnostics diagnostics{};
    check(!DeviceIoControl(first,SES_IOCTL_DIAGNOSTICS,nullptr,0,&diagnostics,sizeof(diagnostics),&bytes,nullptr)&&GetLastError()==ERROR_ACCESS_DENIED,"diagnostics require connected owner");
    check(!DeviceIoControl(first,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0,&bytes,nullptr),"unauthenticated producer denied");
    for(DWORD size=0;size<sizeof(hello);++size)check(!DeviceIoControl(first,SES_IOCTL_CONNECT,&hello,size,&status,sizeof(status),&bytes,nullptr),"short hello rejected");
    auto bad=hello;bad.version=2;check(!DeviceIoControl(first,SES_IOCTL_CONNECT,&bad,sizeof(bad),&status,sizeof(status),&bytes,nullptr),"version mismatch");
    bad=hello;bad.channels=2;check(!DeviceIoControl(first,SES_IOCTL_CONNECT,&bad,sizeof(bad),&status,sizeof(status),&bytes,nullptr),"invalid channels");
    bad=hello;bad.rate=44100;check(!DeviceIoControl(first,SES_IOCTL_CONNECT,&bad,sizeof(bad),&status,sizeof(status),&bytes,nullptr),"invalid rate");
    bad=hello;bad.bits=16;check(!DeviceIoControl(first,SES_IOCTL_CONNECT,&bad,sizeof(bad),&status,sizeof(status),&bytes,nullptr),"producer must use PCM32");
    bad=hello;bad.frames=0;check(!DeviceIoControl(first,SES_IOCTL_CONNECT,&bad,sizeof(bad),&status,sizeof(status),&bytes,nullptr),"invalid hello frames");
    bad=hello;bad.size=0;check(!DeviceIoControl(first,SES_IOCTL_CONNECT,&bad,sizeof(bad),&status,sizeof(status),&bytes,nullptr),"invalid declared hello size");
    check(!DeviceIoControl(first,SES_IOCTL_CONNECT,&hello,sizeof(hello),&status,sizeof(status)-1,&bytes,nullptr),"short status output rejected");
    check(DeviceIoControl(first,SES_IOCTL_CONNECT,&hello,sizeof(hello),&status,sizeof(status),&bytes,nullptr)&&status.version==1&&bytes==sizeof(status),"valid connect");
    for(DWORD size=0;size<sizeof(diagnostics);++size)
        check(!DeviceIoControl(first,SES_IOCTL_DIAGNOSTICS,nullptr,0,&diagnostics,size,&bytes,nullptr)&&GetLastError()==ERROR_INVALID_USER_BUFFER,"short diagnostic output rejected");
    std::array<unsigned char,sizeof(SesDriverDiagnostics)+1> oversized{};
    check(!DeviceIoControl(first,SES_IOCTL_DIAGNOSTICS,nullptr,0,oversized.data(),static_cast<DWORD>(oversized.size()),&bytes,nullptr)&&GetLastError()==ERROR_INVALID_USER_BUFFER,"oversized diagnostic output rejected");
    check(!DeviceIoControl(first,SES_IOCTL_DIAGNOSTICS,&hello,1,&diagnostics,sizeof(diagnostics),&bytes,nullptr)&&GetLastError()==ERROR_INVALID_USER_BUFFER,"diagnostic input must be empty");
    check(DeviceIoControl(first,SES_IOCTL_DIAGNOSTICS,nullptr,0,&diagnostics,sizeof(diagnostics),&bytes,nullptr)&&bytes==sizeof(diagnostics)&&diagnostics.version==SES_DRIVER_DIAGNOSTICS_VERSION&&diagnostics.size==sizeof(diagnostics)&&diagnostics.reserved0==0&&diagnostics.reserved1==0,"owner receives complete initialized diagnostic layout");
    HANDLE second=CreateFileW(SES_DRIVER_PATH,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,0,nullptr);
    if(second!=INVALID_HANDLE_VALUE){check(!DeviceIoControl(second,SES_IOCTL_CONNECT,&hello,sizeof(hello),&status,sizeof(status),&bytes,nullptr),"second owner denied");check(!DeviceIoControl(second,SES_IOCTL_DIAGNOSTICS,nullptr,0,&diagnostics,sizeof(diagnostics),&bytes,nullptr)&&GetLastError()==ERROR_ACCESS_DENIED,"other handle cannot read owner's diagnostics");CloseHandle(second);}else check(false,"second handle opens for ownership test");
    for(DWORD size=0;size<sizeof(packet);size+=31)check(!DeviceIoControl(first,SES_IOCTL_WRITE,&packet,size,nullptr,0,&bytes,nullptr),"short packet rejected");
    packet.frames=0;check(!DeviceIoControl(first,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0,&bytes,nullptr),"zero frame packet rejected");packet.frames=480;
    packet.reserved=1;check(!DeviceIoControl(first,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0,&bytes,nullptr),"reserved packet bits rejected");packet.reserved=0;
    packet.sequence=1;check(!DeviceIoControl(first,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0,&bytes,nullptr),"out-of-order packet rejected");packet.sequence=0;
    check(DeviceIoControl(first,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0,&bytes,nullptr),"valid PCM32 packet");
    check(!DeviceIoControl(first,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0,&bytes,nullptr),"replayed packet rejected");
    check(!DeviceIoControl(first,SES_DRIVER_IOCTL(0x900),nullptr,0,nullptr,0,&bytes,nullptr),"unknown ioctl denied");
    CloseHandle(first);
    first=CreateFileW(SES_DRIVER_PATH,GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,0,nullptr);
    if(first!=INVALID_HANDLE_VALUE){check(DeviceIoControl(first,SES_IOCTL_CONNECT,&hello,sizeof(hello),&status,sizeof(status),&bytes,nullptr)&&status.queued_frames==0,"cleanup releases owner and discards voice");CloseHandle(first);}else check(false,"producer reconnect");
    std::printf("%u lab IOCTL checks, %u failures. Audio silence, sleep, HVCI and Driver Verifier require the separate lab procedure.\n",checks,failures);return failures?1:0;
}
