// Offline analysis is safe on the daily host. Active capture/IOCTLs are lab-only.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <devicetopology.h>
#include <cfgmgr32.h>
#include <devpkey.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cwchar>
#include <limits>
#include <string>
#include <vector>
#include "../../driver/shared/ses_driver_protocol.h"
#include "../../driver/shared/pcm_ring.h"

namespace {
constexpr double pi = 3.14159265358979323846;
constexpr GUID pcmSubtype={WAVE_FORMAT_PCM,0,0x0010,{0x80,0,0,0xaa,0,0x38,0x9b,0x71}};
constexpr unsigned rate = 48000;
constexpr unsigned minSignalFrames = 24000;
constexpr unsigned minSilenceFrames = 4800;
constexpr size_t maxCaptureFrames = 96000;
struct Report {
    unsigned checks=0, failures=0, unsupported=0, selfTests=0, verifiedEndpoints=0;
    unsigned formatsPassed=0, packetsWritten=0, packetsCaptured=0, signalFrames=0, silenceFrames=0;
    void check(bool ok, const char* label) {
        ++checks;
        if (!ok) ++failures;
        std::printf("%s %s\n", ok ? "Passed" : "Findings", label);
    }
    bool json(const char* path) const {
        FILE* file = std::fopen(path, "wb");
        if (!file) return false;
        const int n = std::fprintf(file,
            "{\"schema\":1,\"checks\":%u,\"failures\":%u,\"unsupported\":%u,"
            "\"self_tests\":%u,\"verified_endpoints\":%u,\"formats_passed\":%u,"
            "\"packets_written\":%u,\"packets_captured\":%u,\"signal_frames\":%u,\"silence_frames\":%u}\n",
            checks, failures, unsupported, selfTests, verifiedEndpoints, formatsPassed,
            packetsWritten, packetsCaptured, signalFrames, silenceFrames);
        return std::fclose(file) == 0 && n > 0;
    }
};
template<class T> struct Com {
    T* p=nullptr;
    ~Com() { if (p) p->Release(); }
    Com()=default;
    Com(const Com&)=delete;
    Com& operator=(const Com&)=delete;
    T** out() { return &p; }
    T* operator->() const { return p; }
};
struct Handle {
    HANDLE h=INVALID_HANDLE_VALUE;
    ~Handle() { close(); }
    void close() { if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h); h=INVALID_HANDLE_VALUE; }
};
struct TaskString { wchar_t* p=nullptr; ~TaskString(){CoTaskMemFree(p);} };
struct WaveMemory { WAVEFORMATEX* p=nullptr; ~WaveMemory(){CoTaskMemFree(p);} };
struct PropertyValue { PROPVARIANT value{}; ~PropertyValue(){PropVariantClear(&value);} };
struct ComApartment {
    HRESULT result=CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~ComApartment(){if(SUCCEEDED(result))CoUninitialize();}
};
uint64_t qpc100ns() {
    LARGE_INTEGER counter{}, frequency{};
    QueryPerformanceCounter(&counter); QueryPerformanceFrequency(&frequency);
    return static_cast<uint64_t>((counter.QuadPart / frequency.QuadPart) * 10000000 +
        (counter.QuadPart % frequency.QuadPart) * 10000000 / frequency.QuadPart);
}
double waveform(uint64_t frame, double speed=1.0) {
    const double phase=2*pi*375*static_cast<double>(frame)*speed/rate;
    return .20*std::sin(phase) + .08*std::sin(3*phase);
}
int32_t pcm32(uint64_t frame) {
    return static_cast<int32_t>(std::llround(waveform(frame)*2147483648.0));
}
double decode(const BYTE* data, unsigned bits, unsigned frame) {
    // memcpy avoids alignment and aliasing assumptions about WASAPI buffers.
    if(bits==16) { int16_t value; std::memcpy(&value,data+frame*2,2); return value/32768.0; }
    int32_t value; std::memcpy(&value,data+frame*4,4); return value/2147483648.0;
}
bool silence(const std::vector<double>& data) {
    if(data.size()<minSilenceFrames)return false;
    return std::all_of(data.begin(),data.end(),[](double x){return std::isfinite(x)&&std::abs(x)<=1.0/32768.0;});
}
// Fit both injected tones over independent windows. The clock correction in
// PcmRing changes phase slowly, so a single whole-recording phase fit is wrong.
bool faithful(const std::vector<double>& data) {
    if(data.size()<minSignalFrames || data.size()>maxCaptureFrames)return false;
    constexpr size_t window=2048;
    size_t good=0, total=0;
    for(size_t offset=0;offset+window<=data.size();offset+=window) {
        ++total;
        double energy=0;
        for(size_t i=0;i<window;++i) {
            const double x=data[offset+i];
            if(!std::isfinite(x)||std::abs(x)>.35)return false;
            energy+=x*x;
        }
        const double rms=std::sqrt(energy/window);
        if(rms<.10||rms>.20)continue;
        double best=std::numeric_limits<double>::infinity();
        // +/- .6% covers the driver's bounded +/- .5% clock correction.
        for(int step=-12;step<=12;++step) {
            const double omega=2*pi*375*(1+step*.0005)/rate;
            double s1=0,c1=0,s3=0,c3=0;
            for(size_t i=0;i<window;++i) {
                const double phase=omega*i, x=data[offset+i];
                s1+=x*std::sin(phase); c1+=x*std::cos(phase);
                s3+=x*std::sin(3*phase); c3+=x*std::cos(3*phase);
            }
            s1*=2.0/window;c1*=2.0/window;s3*=2.0/window;c3*=2.0/window;
            const double a1=std::hypot(s1,c1), a3=std::hypot(s3,c3);
            if(a1<.18||a1>.22||a3<.065||a3>.095)continue;
            // The third harmonic must keep the injected phase relationship,
            // not just have the right frequency and level.
            if(std::cos(std::atan2(c3,s3)-3*std::atan2(c1,s1))<std::cos(.25))continue;
            double residual=0;
            for(size_t i=0;i<window;++i) {
                const double phase=omega*i;
                const double error=data[offset+i]-(s1*std::sin(phase)+c1*std::cos(phase)+
                    s3*std::sin(3*phase)+c3*std::cos(3*phase));
                residual+=error*error;
            }
            best=std::min(best,std::sqrt(residual/window)/rms);
        }
        if(best<.08)++good;
    }
    // Small startup scheduling loss is tolerated; all-silence or a tiny burst is not.
    return total>=11 && good*100>=total*90;
}
bool freshPacket(uint64_t stamp, uint64_t cutoff, DWORD flags) {
    return stamp>=cutoff && !(flags&(AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR|AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY));
}
void selfTest(Report& r) {
    auto check=[&](bool ok,const char* name){++r.selfTests;r.check(ok,name);};
    std::vector<double> signal(32768), quiet(minSilenceFrames,0);
    for(size_t i=0;i<signal.size();++i)signal[i]=waveform(i+173);
    check(faithful(signal),"analyzer accepts deterministic signal with arbitrary phase");
    for(double speed:{.995,1.005}) {
        for(size_t i=0;i<signal.size();++i)signal[i]=waveform(i+79,speed);
        check(faithful(signal),"analyzer accepts bounded producer/capture clock drift");
    }
    std::fill(signal.begin(),signal.end(),0);
    check(!faithful(signal),"analyzer rejects all-silence signal");
    std::fill(signal.begin(),signal.end(),.15);
    check(!faithful(signal),"analyzer rejects DC in place of waveform");
    for(size_t i=0;i<signal.size();++i)signal[i]=.2*std::sin(2*pi*997*i/rate);
    check(!faithful(signal),"analyzer rejects unrelated audible tone");
    for(size_t i=0;i<signal.size();++i)signal[i]=.2*std::sin(2*pi*375*i/rate);
    check(!faithful(signal),"analyzer rejects missing harmonic");
    for(size_t i=0;i<signal.size();++i) {
        const double phase=2*pi*375*i/rate;
        signal[i]=.2*std::sin(phase)+.08*std::sin(3*phase+pi/2);
    }
    check(!faithful(signal),"analyzer rejects distorted harmonic phase relationship");
    for(size_t i=0;i<signal.size();++i)signal[i]=i<2048?waveform(i):0;
    check(!faithful(signal),"analyzer rejects one good burst followed by silence");
    for(size_t i=0;i<signal.size();++i)signal[i]=waveform(i);
    signal[0]=std::numeric_limits<double>::quiet_NaN();
    check(!faithful(signal),"analyzer rejects non-finite samples");
    check(!faithful(std::vector<double>(100, .1)),"analyzer rejects short observation");
    check(silence(quiet),"silence analyzer accepts fresh zero PCM");
    quiet.back()=.01;
    check(!silence(quiet),"silence analyzer rejects stale voice");
    check(!silence(std::vector<double>(100,0)),"silence analyzer requires 100 ms observation");
    check(!freshPacket(2499999,2500000,0),"timestamp gate rejects pre-cutoff packets");
    check(freshPacket(2500000,2500000,AUDCLNT_BUFFERFLAGS_SILENT),"timestamp gate accepts new silent packets");
    check(!freshPacket(3000000,2500000,AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR),"timestamp gate rejects invalid timestamp");
    check(!freshPacket(3000000,2500000,AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY),"timestamp gate rejects discontinuity");
    BYTE bytes[4]{};int32_t v32=pcm32(19);std::memcpy(bytes,&v32,4);
    check(std::abs(decode(bytes,32,0)-waveform(19))<1e-8,"PCM32 decoder preserves injected amplitude");
    int16_t v16=static_cast<int16_t>(v32/65536);std::memcpy(bytes,&v16,2);
    check(std::abs(decode(bytes,16,0)-waveform(19))<1.0/32768,"PCM16 decoder preserves injected amplitude");
    for(unsigned bits:{16u,32u}) {
        ses_driver::PcmRing ring;SesDriverHello hello{1,sizeof(hello),rate,1,32,480};
        bool valid=ring.connect(hello,0);uint64_t sequence=0;
        auto push=[&](uint64_t now){
            SesDriverPacket packet{1,sizeof(packet),480,0,sequence,{}};
            for(unsigned i=0;i<480;++i)packet.pcm[i]=pcm32(sequence*480+i);
            ++sequence;return ring.push(packet,now);
        };
        for(unsigned i=0;i<3;++i)valid=push(0)&&valid;
        signal.clear();alignas(int32_t) BYTE block[480*4]{};
        for(unsigned tick=0;tick<90;++tick) {
            ring.pull(block,480,bits,tick*10);
            if(tick>=10)for(unsigned i=0;i<480;++i)signal.push_back(decode(block,bits,i));
            valid=push(tick*10)&&valid;
        }
        check(valid&&faithful(signal),"analyzer accepts actual ring interpolation and PCM conversion");
        ring.disconnect();ring.pull(block,480,bits,1150);quiet.clear();
        for(unsigned tick=0;tick<10;++tick) {
            ring.pull(block,480,bits,1150+tick*10);
            for(unsigned i=0;i<480;++i)quiet.push_back(decode(block,bits,i));
        }
        check(silence(quiet),"actual ring disconnect produces zero PCM");
    }
}

// Exact multi-string comparison: prefix matches and friendly names are unsafe.
bool propertyHasHardwareId(DEVINST node) {
    wchar_t values[4096]{};ULONG size=sizeof(values);DEVPROPTYPE type=0;
    if(CM_Get_DevNode_PropertyW(node,&DEVPKEY_Device_HardwareIds,&type,
        reinterpret_cast<PBYTE>(values),&size,0)!=CR_SUCCESS || type!=DEVPROP_TYPE_STRING_LIST ||
        size<2*sizeof(wchar_t)||size>sizeof(values)||size%sizeof(wchar_t))return false;
    const size_t count=size/sizeof(wchar_t);
    if(values[count-1]!=0||values[count-2]!=0)return false;
    for(size_t i=0;i<count&&values[i];) {
        size_t end=i;while(end<count&&values[end])++end;
        if(end==count)return false;
        if(!_wcsicmp(values+i,SES_DRIVER_HARDWARE_ID))return true;
        i=end+1;
    }
    return false;
}
bool serviceMatches(DEVINST node) {
    wchar_t service[256]{};ULONG size=sizeof(service);DEVPROPTYPE type=0;
    return CM_Get_DevNode_PropertyW(node,&DEVPKEY_Device_Service,&type,
        reinterpret_cast<PBYTE>(service),&size,0)==CR_SUCCESS && type==DEVPROP_TYPE_STRING &&
        size>=sizeof(wchar_t)&&size<=sizeof(service)&&size%sizeof(wchar_t)==0&&
        service[size/sizeof(wchar_t)-1]==0&&!_wcsicmp(service,L"SesMicrophone");
}
bool verifiedTopology(IMMDevice* device,IMMDeviceEnumerator* enumerator) {
    Com<IDeviceTopology> topology;
    if(FAILED(device->Activate(__uuidof(IDeviceTopology),CLSCTX_ALL,nullptr,
        reinterpret_cast<void**>(topology.out()))))return false;
    UINT count=0;
    if(FAILED(topology->GetConnectorCount(&count))||count!=1)return false;
    Com<IConnector> endpointConnector;TaskString interfaceId;
    if(FAILED(topology->GetConnector(0,endpointConnector.out()))||
        FAILED(endpointConnector->GetDeviceIdConnectedTo(&interfaceId.p)))return false;
    // Topology IDs are opaque: obtain the adapter's documented property store
    // rather than parsing the ID or assuming it is a PnP interface path.
    Com<IMMDevice> adapter;Com<IPropertyStore> properties;PropertyValue instance;
    if(!interfaceId.p||FAILED(enumerator->GetDevice(interfaceId.p,adapter.out()))||
        FAILED(adapter->OpenPropertyStore(STGM_READ,properties.out()))||
        FAILED(properties->GetValue(PKEY_Device_InstanceId,&instance.value))||
        instance.value.vt!=VT_LPWSTR||!instance.value.pwszVal||
        wcsnlen(instance.value.pwszVal,4096)>=4096)return false;
    DEVINST node=0;
    if(CM_Locate_DevNodeW(&node,instance.value.pwszVal,CM_LOCATE_DEVNODE_NORMAL)!=CR_SUCCESS)return false;
    // Connected topology normally identifies the root adapter directly. Bound
    // parent walking for implementations that expose an intermediate child.
    for(unsigned depth=0;depth<8;++depth) {
        if(propertyHasHardwareId(node)&&serviceMatches(node))return true;
        DEVINST parent=0;if(CM_Get_Parent(&parent,node,0)!=CR_SUCCESS)break;node=parent;
    }
    return false;
}
bool findDevice(Com<IMMDevice>& selected,Report& r) {
    Com<IMMDeviceEnumerator> enumerator;Com<IMMDeviceCollection> devices;
    if(FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator),reinterpret_cast<void**>(enumerator.out())))||
        FAILED(enumerator->EnumAudioEndpoints(eCapture,DEVICE_STATE_ACTIVE,devices.out())))return false;
    UINT count=0;if(FAILED(devices->GetCount(&count))||count>1024)return false;
    for(UINT i=0;i<count;++i) {
        Com<IMMDevice> candidate;
        if(FAILED(devices->Item(i,candidate.out()))||!verifiedTopology(candidate.p,enumerator.p))continue;
        ++r.verifiedEndpoints;
        if(!selected.p){selected.p=candidate.p;candidate.p=nullptr;}
    }
    return r.verifiedEndpoints==1;
}
// Cancellation is bounded. A broken kernel that fails cancellation cannot be
// made safe by reusing an OVERLAPPED or freeing its buffers: exit the process.
bool ioctl(HANDLE driver,DWORD code,void* input,DWORD inputSize,void* output,DWORD outputSize,DWORD& bytes) {
    Handle event;event.h=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    if(!event.h)return false;
    OVERLAPPED operation{};operation.hEvent=event.h;bytes=0;
    if(DeviceIoControl(driver,code,input,inputSize,output,outputSize,&bytes,&operation))return true;
    if(GetLastError()!=ERROR_IO_PENDING)return false;
    if(WaitForSingleObject(event.h,200)!=WAIT_OBJECT_0) {
        CancelIoEx(driver,&operation);
        if(WaitForSingleObject(event.h,500)!=WAIT_OBJECT_0) {
            std::puts("Findings kernel IOCTL cancellation deadline exceeded; process terminates.");
            std::fflush(stdout);ExitProcess(5);
        }
        GetOverlappedResult(driver,&operation,&bytes,FALSE);
        return false;
    }
    return GetOverlappedResult(driver,&operation,&bytes,FALSE)!=FALSE;
}
struct AudioStop {
    IAudioClient* client;bool started=false;
    ~AudioStop(){if(started)client->Stop();}
};
bool runFormat(IMMDevice* device,unsigned bits,Report& r) {
    const unsigned before=r.failures;
    Com<IAudioClient> client;Com<IAudioCaptureClient> capture;
    if(FAILED(device->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,reinterpret_cast<void**>(client.out())))) {
        r.check(false,"activate exact verified capture endpoint");return false;
    }
    WAVEFORMATEXTENSIBLE format{};
    format.Format={WAVE_FORMAT_EXTENSIBLE,1,rate,rate*(bits/8),static_cast<WORD>(bits/8),static_cast<WORD>(bits),22};
    format.Samples.wValidBitsPerSample=static_cast<WORD>(bits);format.dwChannelMask=SPEAKER_FRONT_CENTER;
    format.SubFormat=pcmSubtype;
    WaveMemory closest;
    const HRESULT supported=client->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED,&format.Format,&closest.p);
    if(supported==S_FALSE||supported==AUDCLNT_E_UNSUPPORTED_FORMAT) {
        ++r.unsupported;std::printf("Not run PCM%u 48000 Hz mono shared format unsupported (not a pass).\n",bits);return false;
    }
    r.check(supported==S_OK,"requested PCM format supported without substitution");
    if(supported!=S_OK)return false;
    HRESULT hr=client->Initialize(AUDCLNT_SHAREMODE_SHARED,0,1000000,0,&format.Format,nullptr);
    r.check(SUCCEEDED(hr),"initialize shared capture without automatic format conversion");
    if(FAILED(hr))return false;
    if(FAILED(client->GetService(__uuidof(IAudioCaptureClient),reinterpret_cast<void**>(capture.out())))) {
        r.check(false,"acquire capture client");return false;
    }
    Handle driver;
    driver.h=CreateFileW(SES_DRIVER_PATH,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,
        nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
    r.check(driver.h!=INVALID_HANDLE_VALUE,"open private driver producer after endpoint verification");
    if(driver.h==INVALID_HANDLE_VALUE)return false;
    SesDriverHello hello{SES_DRIVER_PROTOCOL,sizeof(hello),rate,1,32,SES_DRIVER_FRAMES};
    SesDriverStatus status{};DWORD bytes=0;
    const bool connected=ioctl(driver.h,SES_IOCTL_CONNECT,&hello,sizeof(hello),&status,sizeof(status),bytes)&&
        bytes==sizeof(status)&&status.version==SES_DRIVER_PROTOCOL&&status.size==sizeof(status)&&
        status.connected==1&&status.queued_frames==0;
    r.check(connected,"exclusive producer connects with empty queue and valid status");
    if(!connected)return false;
    uint64_t sequence=0;
    auto write=[&](){
        SesDriverPacket packet{SES_DRIVER_PROTOCOL,sizeof(packet),SES_DRIVER_FRAMES,0,sequence,{}};
        for(unsigned i=0;i<SES_DRIVER_FRAMES;++i)packet.pcm[i]=pcm32(sequence*SES_DRIVER_FRAMES+i);
        if(!ioctl(driver.h,SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0,bytes))return false;
        ++sequence;++r.packetsWritten;return true;
    };
    // Three packets let the driver's reserve prime before the first read.
    for(unsigned i=0;i<3;++i)if(!write()){r.check(false,"bounded producer prefill");return false;}
    AudioStop stop{client.p};hr=client->Start();stop.started=SUCCEEDED(hr);
    r.check(stop.started,"start only the verified virtual microphone capture");
    if(!stop.started)return false;
    std::vector<double> signal,quiet;signal.reserve(maxCaptureFrames);quiet.reserve(24000);
    const uint64_t began=GetTickCount64();uint64_t nextWrite=began+10;
    const uint64_t signalCutoff=qpc100ns()+2500000;
    uint64_t silenceCutoff=0, disconnectedAt=0, previousPosition=0,previousStamp=0;
    bool hadPacket=false,disconnected=false,ok=true;
    while(GetTickCount64()-began<2300) {
        const uint64_t now=GetTickCount64();
        if(!disconnected&&now-began>=1250) {
            driver.close();disconnected=true;disconnectedAt=GetTickCount64();
            silenceCutoff=qpc100ns()+2500000; // excludes queued engine audio and the 100 ms driver timeout.
        }
        if(!disconnected&&now>=nextWrite) {
            if(now-nextWrite>50||sequence>=160||!write()){ok=false;break;}
            nextWrite+=10;
        }
        UINT32 frames=0;
        if(FAILED(capture->GetNextPacketSize(&frames))){ok=false;break;}
        unsigned drained=0;
        while(frames) {
            if(++drained>128){ok=false;break;}
            BYTE* data=nullptr;DWORD flags=0;UINT64 position=0,stamp=0;
            hr=capture->GetBuffer(&data,&frames,&flags,&position,&stamp);
            if(FAILED(hr)){ok=false;break;}
            bool valid=frames>0&&frames<=rate&&
                ((flags&AUDCLNT_BUFFERFLAGS_SILENT)||data);
            if(hadPacket&&(position<previousPosition||stamp<=previousStamp))valid=false;
            if(stamp>qpc100ns()+100000)valid=false; // reject fabricated future timestamps (>10 ms).
            if(position>std::numeric_limits<uint64_t>::max()-frames)valid=false;
            std::vector<double>* destination=nullptr;
            if(!disconnected&&stamp>=signalCutoff)destination=&signal;
            if(disconnected&&GetTickCount64()-disconnectedAt>=250&&stamp>=silenceCutoff)destination=&quiet;
            if(destination) {
                if(!freshPacket(stamp,disconnected?silenceCutoff:signalCutoff,flags)||
                    destination->size()+frames>maxCaptureFrames||
                    (hadPacket&&position!=previousPosition))valid=false;
                if(valid)for(UINT32 i=0;i<frames;++i)destination->push_back(
                    flags&AUDCLNT_BUFFERFLAGS_SILENT?0:decode(data,bits,i));
            }
            if(valid){previousPosition=position+frames;previousStamp=stamp;hadPacket=true;}
            ++r.packetsCaptured;
            if(FAILED(capture->ReleaseBuffer(frames)))valid=false;
            if(!valid){ok=false;break;}
            if(FAILED(capture->GetNextPacketSize(&frames))){ok=false;break;}
        }
        if(!ok)break;
        if(disconnected&&GetTickCount64()-disconnectedAt>=350&&quiet.size()>=minSilenceFrames)break;
        Sleep(1);
    }
    // Even failure paths close producer before stopping capture; RAII releases COM.
    driver.close();r.signalFrames+=static_cast<unsigned>(signal.size());
    r.silenceFrames+=static_cast<unsigned>(quiet.size());
    std::printf("PCM%u observations: %zu signal frames, %zu fresh silence frames.\n",bits,signal.size(),quiet.size());
    r.check(ok,"bounded capture has valid buffers and monotonic positions/timestamps");
    r.check(faithful(signal),"captured nonzero deterministic waveform retains amplitude and both tones");
    r.check(disconnected&&silence(quiet),"producer close yields 100 ms fresh silence after 250 ms guard");
    if(r.failures==before){++r.formatsPassed;return true;}return false;
}
}

int main(int argc,char** argv) {
    bool offline=false,lab=false;const char* reportPath=nullptr;
    for(int i=1;i<argc;++i) {
        if(!std::strcmp(argv[i],"--self-test"))offline=true;
        else if(!std::strcmp(argv[i],"--isolated-lab"))lab=true;
        else if(!std::strcmp(argv[i],"--json-report")&&i+1<argc&&!reportPath)reportPath=argv[++i];
        else {std::puts("Usage: ses_driver_capture_lab_tests (--self-test | --isolated-lab) [--json-report path]");return 2;}
    }
    if(offline==lab) {
        std::puts("Choose --self-test (offline) or --isolated-lab (dedicated Windows VM/test machine).");return 2;
    }
    Report report;
    if(offline)selfTest(report);
    else {
        std::puts("--isolated-lab is an acknowledgement, not isolation. Run only in a dedicated lab.");
        ComApartment apartment;
        report.check(SUCCEEDED(apartment.result),"initialize COM apartment");
        if(SUCCEEDED(apartment.result)) {
            Com<IMMDevice> selected;
            const bool found=findDevice(selected,report);
            report.check(found,"exactly one capture endpoint maps to ROOT\\SES_MICROPHONE and service SesMicrophone");
            if(found){runFormat(selected.p,16,report);runFormat(selected.p,32,report);}
        }
    }
    std::printf("%u checks, %u findings, %u unsupported formats; %u capture formats passed.\n",
        report.checks,report.failures,report.unsupported,report.formatsPassed);
    if(reportPath&&!report.json(reportPath)){std::puts("Findings JSON report could not be written.");return 1;}
    if(report.failures)return 1;
    if(report.unsupported)return 4; // Incomplete acceptance is never a full pass.
    return 0;
}
