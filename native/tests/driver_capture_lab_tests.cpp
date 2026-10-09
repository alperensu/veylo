// Offline analysis is safe on the daily host. Active capture/IOCTLs are lab-only.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
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
#include <array>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <type_traits>
#include "../../driver/shared/ses_driver_protocol.h"
#include "../../driver/shared/pcm_ring.h"
#include "../src/driver_bridge.hpp"

namespace {
constexpr double pi = 3.14159265358979323846;
constexpr GUID pcmSubtype={WAVE_FORMAT_PCM,0,0x0010,{0x80,0,0,0xaa,0,0x38,0x9b,0x71}};
constexpr unsigned rate = 48000;
constexpr unsigned minSignalFrames = 24000;
constexpr unsigned minSilenceFrames = 4800;
constexpr size_t maxCaptureFrames = 96000;
struct ExtendedClientEvidence {
    uint64_t packets=0, frames=0, discontinuities=0, timestampErrors=0, gaps=0;
    unsigned windows[3]{}, silenceChecks=0, reconnects=0;
};
struct ProducerStatusObservation {
    uint64_t sample=0,elapsed100ns=0,due100ns=0,lateness100ns=0,statusDuration100ns=0;
    uint64_t lastWriteGap100ns=0,sinceWrite100ns=0,received=0,silence=0;
    uint64_t workerPublicationAge100ns=0;
    uint32_t queued=0,underruns=0,overruns=0;
    int32_t drift=0;
    unsigned phase=0;
    bool steady=false;
};
// Retain the failure-near history without allocating or logging on the audio worker.
// Readers receive this storage through the existing publication snapshot.
struct ProducerStatusHistory {
    static constexpr size_t capacity=64;
    std::array<ProducerStatusObservation,capacity> observations{};
    size_t count=0,next=0;
    void append(const ProducerStatusObservation& observation) {
        observations[next]=observation;next=(next+1)%capacity;
        if(count<capacity)++count;
    }
    const ProducerStatusObservation& oldest(size_t index)const {
        return observations[(next+capacity-count+index)%capacity];
    }
};
struct ExtendedEvidence {
    bool requested=false, ran=false;
    bool product=false,workerMmcss=false;
    uint64_t submittedPackets=0;
    uint64_t maxWorkerPublicationAge100ns=0;
    uint32_t queueDrops=0,sourceSessions=0,bridgeStatus=0,bridgeLastError=0;
    unsigned requestedSeconds=0;
    uint64_t elapsedMs=0, writes=0, maxLatenessMs=0, maxWriteGap100ns=0, maxIoctl100ns=0;
    uint32_t minimumQueuedSteady=std::numeric_limits<uint32_t>::max();
    bool mmcss=false,consumerMmcss=false;
    uint64_t maxConsumerDrainGap100ns=0;
    unsigned statusSamples=0, producerReconnects=0;
    uint64_t driverReceivedFrames=0, driverSilenceFrames=0;
    uint32_t driverUnderruns=0, driverOverruns=0, steadyUnderruns=0;
    ProducerStatusHistory statusHistory;
    ExtendedClientEvidence clients[2];
};
struct Report {
    unsigned checks=0, failures=0, unsupported=0, selfTests=0, verifiedEndpoints=0;
    unsigned formatsPassed=0, packetsWritten=0, packetsCaptured=0, signalFrames=0, silenceFrames=0;
    ExtendedEvidence extended;
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
            "\"packets_written\":%u,\"packets_captured\":%u,\"signal_frames\":%u,\"silence_frames\":%u,",
            checks, failures, unsupported, selfTests, verifiedEndpoints, formatsPassed,
            packetsWritten, packetsCaptured, signalFrames, silenceFrames);
        bool ok=n>0;
        const auto& e=extended;
        ok=std::fprintf(file,"\"extended_kernel_capture\":{\"requested\":%s,\"ran\":%s,"
            "\"mode\":\"%s\","
            "\"scope\":\"two_shared_WASAPI_clients_one_process_PCM32_not_two_applications\","
            "\"requested_seconds\":%u,\"elapsed_ms\":%llu,\"writes\":%llu,\"maximum_producer_lateness_ms\":%llu,"
            "\"maximum_steady_write_completion_gap_us\":%llu,\"maximum_ioctl_duration_us\":%llu,"
            "\"minimum_queued_frames_steady\":%u,\"producer_mmcss_pro_audio\":%s,"
            "\"consumer_mmcss_pro_audio\":%s,\"max_consumer_drain_gap_us\":%llu,"
            "\"status_samples\":%u,\"producer_reconnects\":%u,\"driver_received_frames\":%llu,"
            "\"driver_silence_frames\":%llu,\"driver_underruns\":%u,\"driver_overruns\":%u,\"steady_underruns\":%u,\"clients\":[",
            e.requested?"true":"false",e.ran?"true":"false",e.product?"production_driver_bridge":"strict_synthetic_producer",e.requestedSeconds,
            static_cast<unsigned long long>(e.elapsedMs),static_cast<unsigned long long>(e.writes),
            static_cast<unsigned long long>(e.maxLatenessMs),static_cast<unsigned long long>(e.maxWriteGap100ns/10),
            static_cast<unsigned long long>(e.maxIoctl100ns/10),
            e.minimumQueuedSteady==std::numeric_limits<uint32_t>::max()?0:e.minimumQueuedSteady,e.mmcss?"true":"false",
            e.consumerMmcss?"true":"false",static_cast<unsigned long long>(e.maxConsumerDrainGap100ns/10),
            e.statusSamples,e.producerReconnects,
            static_cast<unsigned long long>(e.driverReceivedFrames),static_cast<unsigned long long>(e.driverSilenceFrames),
            e.driverUnderruns,e.driverOverruns,e.steadyUnderruns)>0&&ok;
        for(unsigned i=0;i<2;++i) {
            const auto& c=e.clients[i];
            ok=std::fprintf(file,"%s{\"packets\":%llu,\"frames\":%llu,\"discontinuities\":%llu,\"timestamp_errors\":%llu,"
                "\"position_gaps\":%llu,\"waveform_windows_by_signal_stage\":[%u,%u,%u],\"fresh_silence_checks\":%u,\"reconnects\":%u}",
                i?",":"",static_cast<unsigned long long>(c.packets),static_cast<unsigned long long>(c.frames),
                static_cast<unsigned long long>(c.discontinuities),static_cast<unsigned long long>(c.timestampErrors),
                static_cast<unsigned long long>(c.gaps),c.windows[0],c.windows[1],c.windows[2],c.silenceChecks,c.reconnects)>0&&ok;
        }
        ok=std::fprintf(file,"],\"producer_status_history\":{\"capacity\":%zu,\"count\":%zu,"
            "\"time_origin\":\"producer_measured_QPC_begin\",\"source\":\"%s\",\"status_duration_available\":%s,"
            "\"worker_publication_age_available\":%s,\"observations\":[",
            ProducerStatusHistory::capacity,e.statusHistory.count,e.product?"bridge_worker_atomic_snapshot":"strict_producer_STATUS_ioctl",
            e.product?"false":"true",e.product?"true":"false")>0&&ok;
        for(size_t i=0;i<e.statusHistory.count;++i) {
            const auto& o=e.statusHistory.oldest(i);
            ok=std::fprintf(file,"%s{\"sample\":%llu,\"elapsed_us\":%llu,\"due_us\":%llu,\"lateness_us\":%llu,"
                "\"status_duration_us\":%llu,\"worker_status_publication_age_us\":%llu,"
                "\"last_write_completion_gap_us\":%llu,\"since_last_write_completion_us\":%llu,"
                "\"phase\":%u,\"steady\":%s,\"queued_frames\":%u,\"drift_ppm\":%d,"
                "\"driver_received_frames\":%llu,\"driver_silence_frames\":%llu,\"driver_underruns\":%u,\"driver_overruns\":%u}",
                i?",":"",static_cast<unsigned long long>(o.sample),static_cast<unsigned long long>(o.elapsed100ns/10),
                static_cast<unsigned long long>(o.due100ns/10),static_cast<unsigned long long>(o.lateness100ns/10),
                static_cast<unsigned long long>(o.statusDuration100ns/10),static_cast<unsigned long long>(o.workerPublicationAge100ns/10),
                static_cast<unsigned long long>(o.lastWriteGap100ns/10),
                static_cast<unsigned long long>(o.sinceWrite100ns/10),o.phase,o.steady?"true":"false",o.queued,o.drift,
                static_cast<unsigned long long>(o.received),static_cast<unsigned long long>(o.silence),o.underruns,o.overruns)>0&&ok;
        }
        ok=std::fprintf(file,"]},\"product_bridge\":{\"requested\":%s,\"ran\":%s,"
            "\"source\":\"native/src/driver_bridge.hpp\",\"upstream_packet_frames\":480,\"upstream_packet_period_us\":10000,"
            "\"transfer_queue_capacity_packets\":4,\"worker_period_us\":2000,\"driver_write_threshold_frames\":961,"
            "\"worker_mmcss_pro_audio\":%s,\"queue_drops\":%u,\"submitted_packets\":%llu,\"source_sessions\":%u,"
            "\"last_observed_status\":%u,\"last_observed_error\":%u,"
            "\"maximum_worker_status_publication_age_us\":%llu,"
            "\"driver_counter_scope\":\"sum_of_connected_source_session_deltas_excludes_disconnected_holds\","
            "\"bounded_flush_deadline_ms\":150}}}\n",e.product&&e.requested?"true":"false",e.product&&e.ran?"true":"false",
            e.workerMmcss?"true":"false",e.queueDrops,static_cast<unsigned long long>(e.submittedPackets),e.sourceSessions,
            e.bridgeStatus,e.bridgeLastError,static_cast<unsigned long long>(e.maxWorkerPublicationAge100ns/10))>0&&ok;
        return std::fclose(file)==0&&ok;
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
struct MmcssAudio {
    DWORD index=0;
    HANDLE task=AvSetMmThreadCharacteristicsW(L"Pro Audio",&index);
    bool ready=task&&AvSetMmThreadPriority(task,AVRT_PRIORITY_HIGH);
    MmcssAudio()=default;
    MmcssAudio(const MmcssAudio&)=delete;
    MmcssAudio& operator=(const MmcssAudio&)=delete;
    ~MmcssAudio(){if(task)AvRevertMmThreadCharacteristics(task);}
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
    // Sleep(1) may sleep an entire default Windows clock tick (~15.6 ms).
    // That made this 10 ms producer fall behind before its warmup completed.
    // Use a private timer, keeping the existing 50 ms deadline and avoiding a
    // process/system-wide multimedia timer-resolution change.
    Handle pollTimer;
    pollTimer.h=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
        TIMER_MODIFY_STATE|SYNCHRONIZE);
    r.check(pollTimer.h!=nullptr,"create private high-resolution capture test timer");
    if(!pollTimer.h)return false;
    MmcssAudio consumerMmcss;
    r.check(consumerMmcss.ready,"register capture consumer with MMCSS Pro Audio priority");
    if(!consumerMmcss.ready)return false;
    AudioStop stop{client.p};hr=client->Start();stop.started=SUCCEEDED(hr);
    r.check(stop.started,"start only the verified virtual microphone capture");
    if(!stop.started)return false;
    std::vector<double> signal,quiet;signal.reserve(maxCaptureFrames);quiet.reserve(24000);
    const uint64_t began=GetTickCount64();uint64_t nextWrite=began+10;
    const uint64_t signalCutoff=qpc100ns()+2500000;
    uint64_t silenceCutoff=0, disconnectedAt=0, previousPosition=0,previousStamp=0;
    bool hadPacket=false,disconnected=false,ok=true;
    auto abortRun=[&](const char* reason,HRESULT error=S_OK){
        std::printf("PCM%u stopped: %s; elapsed=%llu ms, writes=%llu, HRESULT=0x%08lx\n",
            bits,reason,static_cast<unsigned long long>(GetTickCount64()-began),
            static_cast<unsigned long long>(sequence),static_cast<unsigned long>(error));
        ok=false;
    };
    while(GetTickCount64()-began<2300) {
        const uint64_t now=GetTickCount64();
        if(!disconnected&&now-began>=1250) {
            driver.close();disconnected=true;disconnectedAt=GetTickCount64();
            silenceCutoff=qpc100ns()+2500000; // excludes queued engine audio and the 100 ms driver timeout.
        }
        if(!disconnected&&now>=nextWrite) {
            if(now-nextWrite>50){std::printf("PCM%u producer lateness=%llu ms\n",bits,static_cast<unsigned long long>(now-nextWrite));abortRun("producer scheduler deadline");break;}
            if(sequence>=160){abortRun("producer packet bound");break;}
            if(!write()){abortRun("producer IOCTL write",HRESULT_FROM_WIN32(GetLastError()));break;}
            nextWrite+=10;
        }
        UINT32 frames=0;
        hr=capture->GetNextPacketSize(&frames);
        if(FAILED(hr)){abortRun("capture GetNextPacketSize",hr);break;}
        unsigned drained=0;
        while(frames) {
            if(++drained>128){abortRun("capture drain bound");break;}
            BYTE* data=nullptr;DWORD flags=0;UINT64 position=0,stamp=0;
            hr=capture->GetBuffer(&data,&frames,&flags,&position,&stamp);
            if(FAILED(hr)){abortRun("capture GetBuffer",hr);break;}
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
            hr=capture->ReleaseBuffer(frames);
            if(FAILED(hr)){abortRun("capture ReleaseBuffer",hr);break;}
            if(!valid){
                std::printf("PCM%u invalid packet: frames=%u flags=0x%08lx position=%llu expected=%llu stamp=%llu previous=%llu now=%llu\n",
                    bits,frames,static_cast<unsigned long>(flags),static_cast<unsigned long long>(position),
                    static_cast<unsigned long long>(previousPosition),static_cast<unsigned long long>(stamp),
                    static_cast<unsigned long long>(previousStamp),static_cast<unsigned long long>(qpc100ns()));
                abortRun("capture packet validation");break;
            }
            hr=capture->GetNextPacketSize(&frames);
            if(FAILED(hr)){abortRun("capture GetNextPacketSize during drain",hr);break;}
        }
        if(!ok)break;
        if(disconnected&&GetTickCount64()-disconnectedAt>=350&&quiet.size()>=minSilenceFrames)break;
        LARGE_INTEGER due{};due.QuadPart=-10000;
        if(!SetWaitableTimerEx(pollTimer.h,&due,0,nullptr,nullptr,nullptr,0)){
            abortRun("arm capture test timer",HRESULT_FROM_WIN32(GetLastError()));break;
        }
        const DWORD waited=WaitForSingleObject(pollTimer.h,200);
        if(waited!=WAIT_OBJECT_0){abortRun("capture test timer wait",waited==WAIT_FAILED?HRESULT_FROM_WIN32(GetLastError()):HRESULT_FROM_WIN32(ERROR_TIMEOUT));break;}
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

// The analyzer receives at most four fixed-size blocks. It never calls COM or
// the driver, and cannot cause the producer to miss its existing 50 ms limit.
struct StreamingAnalyzer {
    static constexpr size_t blockFrames=32768, queueBound=4;
    struct Block { unsigned client,stage;std::vector<double> samples; };
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Block> queue;
    std::atomic<bool> failed{false};
    std::atomic<bool> finished{false};
    std::array<std::array<std::atomic<unsigned>,3>,2> windows{};
    bool stopping=false;
    std::thread worker;
    StreamingAnalyzer():worker([this] {
        for(;;) {
            Block block{};
            {
                std::unique_lock<std::mutex> lock(mutex);
                wake.wait(lock,[this]{return stopping||!queue.empty();});
                if(queue.empty()){finished=true;return;}
                block=std::move(queue.front());queue.pop_front();
            }
            if(!faithful(block.samples))failed=true;
            else ++windows[block.client][block.stage];
        }
    }){}
    bool submit(unsigned client,unsigned stage,std::vector<double>& samples) {
        std::lock_guard<std::mutex> lock(mutex);
        if(stopping||queue.size()>=queueBound||samples.size()!=blockFrames)return false;
        queue.push_back({client,stage,std::move(samples)});
        samples=std::vector<double>();samples.reserve(blockFrames);wake.notify_one();return true;
    }
    void finish() {
        {std::lock_guard<std::mutex> lock(mutex);stopping=true;wake.notify_one();}
        if(worker.joinable()) {
            // A thread cannot safely be detached while it owns this object.
            // Fail closed if analysis cannot finish its bounded queue in 10 s.
            const uint64_t end=GetTickCount64()+10000;
            while(!finished&&GetTickCount64()<end)Sleep(1);
            if(!finished){std::puts("Findings analyzer shutdown deadline exceeded; process terminates.");std::fflush(stdout);ExitProcess(5);}
            worker.join();
        }
    }
    ~StreamingAnalyzer(){finish();}
};
struct ExtendedCapture {
    Com<IAudioClient> client;
    Com<IAudioCaptureClient> capture;
    bool started=false,hadPacket=false;
    uint64_t previousPosition=0,previousStamp=0,cutoff=0,lastPacketMs=0,lastDrain100ns=0;
    std::vector<double> signal,quiet;
    ExtendedCapture(){signal.reserve(StreamingAnalyzer::blockFrames);quiet.reserve(minSilenceFrames);}
    void close() {
        if(started)client->Stop();started=false;
        if(capture.p){capture.p->Release();capture.p=nullptr;}
        if(client.p){client.p->Release();client.p=nullptr;}
        hadPacket=false;signal.clear();quiet.clear();
        lastDrain100ns=0;
    }
    ~ExtendedCapture(){close();}
    bool open(IMMDevice* device) {
        close();
        WAVEFORMATEXTENSIBLE format{};
        format.Format={WAVE_FORMAT_EXTENSIBLE,1,rate,rate*4,4,32,22};
        format.Samples.wValidBitsPerSample=32;format.dwChannelMask=SPEAKER_FRONT_CENTER;format.SubFormat=pcmSubtype;
        WaveMemory closest;
        if(FAILED(device->Activate(__uuidof(IAudioClient),CLSCTX_ALL,nullptr,reinterpret_cast<void**>(client.out())))||
            client->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED,&format.Format,&closest.p)!=S_OK||
            FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED,0,1000000,0,&format.Format,nullptr))||
            FAILED(client->GetService(__uuidof(IAudioCaptureClient),reinterpret_cast<void**>(capture.out()))))return false;
        started=SUCCEEDED(client->Start());lastPacketMs=GetTickCount64();return started;
    }
};
bool statusValid(const SesDriverStatus& status,DWORD bytes) {
    return bytes==sizeof(status)&&status.version==SES_DRIVER_PROTOCOL&&status.size==sizeof(status)&&
        status.connected<=1&&status.queued_frames<=SES_DRIVER_CAPACITY&&status.reserved==0&&
        status.drift_ppm>=-5005&&status.drift_ppm<=5005;
}
// All times are QPC 100 ns units. Intentional lifecycle gaps are excluded only
// from write-gap diagnostics; scheduler lateness and driver counters still fail.
struct ProducerSchedule {
    static constexpr uint64_t packetPeriod=100000, pauseDuration=5500000, lifecycleGuard=10000000;
    uint64_t began=0, end=0, nextWrite=0, phaseEpoch=0;
    unsigned phase=0; // 0 signal, 1 paused, 2 signal, 3 closed, 4 signal
    explicit ProducerSchedule(uint64_t now,unsigned seconds):began(now),end(now+seconds*10000000ULL),
        nextWrite(now+packetPeriod),phaseEpoch(now){}
    bool paused()const{return phase==1||phase==3;}
    bool pauseDue(uint64_t now)const {
        return !paused()&&phase<4&&now-began>=(end-began)*(phase/2+1)/3;
    }
    void pause(uint64_t now){++phase;phaseEpoch=now;}
    bool resumeDue(uint64_t now,unsigned permit)const {
        return paused()&&permit>=phase&&now-phaseEpoch>=pauseDuration;
    }
    bool lifecycleExpired(uint64_t now)const{return paused()&&now-phaseEpoch>lifecycleGuard;}
    bool schedulerExpired(uint64_t now)const{return !paused()&&now>nextWrite&&now-nextWrite>500000;}
    bool pauseAllowed(uint64_t now)const{return !schedulerExpired(now)&&pauseDue(now);}
    void resume(uint64_t now){++phase;phaseEpoch=now;nextWrite=now+packetPeriod;}
};
bool lifecycleAcknowledgementExpired(uint64_t now,uint64_t epoch) {
    return now>=epoch&&now-epoch>ProducerSchedule::lifecycleGuard;
}
bool silenceObservationReady(uint64_t now,uint64_t epoch,size_t first,size_t second) {
    return now>=epoch&&now-epoch>=5000000&&first>=minSilenceFrames&&second>=minSilenceFrames;
}
struct ProducerPublication {
    ExtendedEvidence evidence;
    uint64_t began=0,phaseEpoch=0;
    unsigned phase=0;
    bool ready=false,done=false;
    const char* failure=nullptr;
};
// Exactly one publisher and one reader. A preempted reader can pin an old
// slot, but the writer always has a different non-latest slot available.
// Unlike a seqlock over plain fields, every copy has exclusive slot ownership.
// SC ordering also prevents stale latest reads from moving the reader across
// both writer candidates between the two bounded CAS attempts.
class ProducerMailbox {
    struct Slot {
        std::atomic<bool> owned{false};
        ProducerPublication publication{};
    };
    std::array<Slot,3> slots{};
    std::atomic<unsigned> latest{0};
    ProducerPublication cached{}; // Reader-owned, never accessed by the writer.
public:
    static_assert(std::is_trivially_copyable_v<ProducerPublication>);
    static_assert(std::atomic<bool>::is_always_lock_free&&std::atomic<unsigned>::is_always_lock_free);
    bool publish(const ProducerPublication& publication) noexcept {
        const unsigned current=latest.load(std::memory_order_seq_cst);
        for(unsigned offset=1;offset<3;++offset) {
            const unsigned index=(current+offset)%3;bool expected=false;
            if(!slots[index].owned.compare_exchange_strong(expected,true,std::memory_order_seq_cst))continue;
            slots[index].publication=publication;
            latest.store(index,std::memory_order_seq_cst);
            slots[index].owned.store(false,std::memory_order_seq_cst);
            return true;
        }
        return false; // Only a violation of the single-reader contract can exhaust both slots.
    }
    ProducerPublication snapshot(void(*onReadAcquired)(void*) noexcept=nullptr,void* context=nullptr) noexcept {
        for(unsigned attempt=0;attempt<3;++attempt) {
            const unsigned index=latest.load(std::memory_order_seq_cst);bool expected=false;
            if(!slots[index].owned.compare_exchange_strong(expected,true,std::memory_order_seq_cst))continue;
            // The optional hook is used only by offline preemption fixtures.
            if(onReadAcquired)onReadAcquired(context);
            cached=slots[index].publication;
            slots[index].owned.store(false,std::memory_order_seq_cst);
            return cached;
        }
        return cached;
    }
};
bool productDeliveryComplete(uint64_t submitted,uint64_t sent,uint64_t received,uint64_t baseline) {
    return submitted<=std::numeric_limits<uint64_t>::max()/SES_DRIVER_FRAMES&&received>=baseline&&
        sent==submitted*SES_DRIVER_FRAMES&&received-baseline==sent;
}
uint64_t workerPublicationAge(uint64_t sampled,uint64_t published){
    // Independent publication timestamp; the separate counter atomics are
    // not a coherent kernel snapshot. Missing/newer timestamps have no age.
    return published&&sampled>=published?sampled-published:0;
}
bool productFlushComplete(uint64_t submitted,uint64_t sent,uint64_t received,uint64_t baseline,
    uint64_t now,uint64_t deadline) {
    return now<=deadline&&productDeliveryComplete(submitted,sent,received,baseline);
}
bool productTelemetryHealthy(uint32_t status,uint32_t protocol,bool workerMmcss,uint32_t queueDrops,
    uint32_t overruns,uint32_t steadyUnderruns) {
    return status==2&&protocol==SES_DRIVER_PROTOCOL&&workerMmcss&&queueDrops==0&&overruns==0&&steadyUnderruns==0;
}
struct ExtendedProducer {
    ProducerMailbox publication;
    std::atomic<bool> stop{false},finished{false};
    std::atomic<unsigned> resumePermit{0};
    std::thread worker;
    ExtendedProducer(unsigned seconds):worker([this,seconds]{run(seconds);}){}
    ProducerPublication snapshot(){return publication.snapshot();}
    void publish(const ProducerPublication& state){if(!publication.publish(state))std::terminate();}
    void finish() {
        stop=true;
        if(worker.joinable()) {
            const uint64_t deadline=GetTickCount64()+1000;
            while(!finished&&GetTickCount64()<deadline)Sleep(1);
            if(!finished){std::puts("Findings producer shutdown deadline exceeded; process terminates.");std::fflush(stdout);ExitProcess(5);}
            worker.join();
        }
    }
    ~ExtendedProducer(){finish();}
    void run(unsigned seconds) {
        // Driver handle, IOCTL buffers, sequence and status never leave this
        // worker. COM capture/decode and analyzer queue locks run elsewhere.
        ProducerPublication state{};auto& e=state.evidence;
        Handle driver,timer;MmcssAudio mmcss;e.mmcss=mmcss.ready;
        SesDriverStatus status{},baseline{},previous{};DWORD bytes=0;
        uint64_t sequence=0,lastCompletion=0,lastWriteGap=0;bool haveSteadyStatus=false;
        std::array<std::array<int32_t,SES_DRIVER_FRAMES>,4> pcm{};
        for(unsigned p=0;p<4;++p)for(unsigned i=0;i<SES_DRIVER_FRAMES;++i)pcm[p][i]=pcm32(p*SES_DRIVER_FRAMES+i);
        auto call=[&](DWORD code,void* input,DWORD inputBytes,void* output,DWORD outputBytes) {
            const uint64_t started=qpc100ns();
            const bool ok=ioctl(driver.h,code,input,inputBytes,output,outputBytes,bytes);
            e.maxIoctl100ns=std::max(e.maxIoctl100ns,qpc100ns()-started);return ok;
        };
        auto connect=[&]() {
            driver.close();driver.h=CreateFileW(SES_DRIVER_PATH,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,
                nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
            SesDriverHello hello{SES_DRIVER_PROTOCOL,sizeof(hello),rate,1,32,SES_DRIVER_FRAMES};sequence=0;
            return driver.h!=INVALID_HANDLE_VALUE&&call(SES_IOCTL_CONNECT,&hello,sizeof(hello),&status,sizeof(status))&&
                statusValid(status,bytes)&&status.connected==1&&status.queued_frames==0;
        };
        auto write=[&](bool measureGap) {
            SesDriverPacket packet{SES_DRIVER_PROTOCOL,sizeof(packet),SES_DRIVER_FRAMES,0,sequence,{}};
            std::memcpy(packet.pcm,pcm[sequence%4].data(),sizeof(packet.pcm));
            if(e.writes>=seconds*100ULL+16||!call(SES_IOCTL_WRITE,&packet,sizeof(packet),nullptr,0))return false;
            const uint64_t completed=qpc100ns();
            lastWriteGap=measureGap&&lastCompletion?completed-lastCompletion:0;
            if(measureGap&&lastCompletion)e.maxWriteGap100ns=std::max(e.maxWriteGap100ns,lastWriteGap);
            lastCompletion=completed;++sequence;++e.writes;return true;
        };
        auto readStatus=[&](bool steady,uint64_t began,uint64_t due,unsigned phase) {
            const uint64_t started=qpc100ns();
            if(!call(SES_IOCTL_STATUS,nullptr,0,&status,sizeof(status))||!statusValid(status,bytes)||status.connected!=1||
                status.received_frames<previous.received_frames||status.silence_frames<previous.silence_frames||
                status.underruns<previous.underruns||status.overruns<previous.overruns)return false;
            ++e.statusSamples;e.driverReceivedFrames=status.received_frames-baseline.received_frames;
            e.driverSilenceFrames=status.silence_frames-baseline.silence_frames;
            e.driverUnderruns=status.underruns-baseline.underruns;e.driverOverruns=status.overruns-baseline.overruns;
            const uint64_t completed=qpc100ns();
            ProducerStatusObservation observation{};
            observation.sample=e.statusSamples;observation.elapsed100ns=completed>=began?completed-began:0;
            observation.due100ns=due>=began?due-began:0;observation.lateness100ns=started>=due?started-due:0;
            observation.statusDuration100ns=completed>=started?completed-started:0;
            observation.lastWriteGap100ns=lastWriteGap;
            observation.sinceWrite100ns=lastCompletion&&completed>=lastCompletion?completed-lastCompletion:0;
            observation.phase=phase;observation.steady=steady;observation.queued=status.queued_frames;
            observation.drift=status.drift_ppm;observation.received=e.driverReceivedFrames;observation.silence=e.driverSilenceFrames;
            observation.underruns=e.driverUnderruns;observation.overruns=e.driverOverruns;
            // Append before the counter gate, so the rejected observation survives fail().
            e.statusHistory.append(observation);
            if(steady) {
                e.minimumQueuedSteady=std::min(e.minimumQueuedSteady,status.queued_frames);
                if(haveSteadyStatus)e.steadyUnderruns+=status.underruns-previous.underruns;
            }
            previous=status;haveSteadyStatus=steady;
            return e.driverOverruns==0&&e.steadyUnderruns==0;
        };
        auto fail=[&](const char* reason){state.failure=reason;publish(state);};
        timer.h=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
        if(!timer.h||!mmcss.ready)fail("producer private high-resolution timer or MMCSS Pro Audio registration");
        else if(!connect())fail("producer initial connection validates protocol status");
        else {
            baseline=previous=status;bool prefilled=true;
            for(unsigned i=0;i<3;++i)if(!write(false)){prefilled=false;break;}
            if(!prefilled)fail("producer initial bounded prefill");
            else {
                ProducerSchedule schedule(qpc100ns(),seconds);state.began=schedule.began;state.ready=true;
                state.phaseEpoch=schedule.phaseEpoch;publish(state);
                while(!stop&&!state.failure&&qpc100ns()<schedule.end) {
                    uint64_t now=qpc100ns();
                    if(!schedule.paused()&&now>=schedule.nextWrite)
                        e.maxLatenessMs=std::max(e.maxLatenessMs,(now-schedule.nextWrite)/10000);
                    // A lifecycle boundary cannot erase an expired steady write
                    // deadline, including time spent reading its final status.
                    if(schedule.schedulerExpired(now)){fail("producer scheduler exceeds existing 50 ms deadline before lifecycle");break;}
                    if(schedule.pauseAllowed(now)) {
                        if(!readStatus(true,schedule.began,schedule.nextWrite,schedule.phase)){fail("driver counters before lifecycle change");break;}
                        now=qpc100ns();
                        if(now>=schedule.nextWrite)e.maxLatenessMs=std::max(e.maxLatenessMs,(now-schedule.nextWrite)/10000);
                        if(schedule.schedulerExpired(now)){fail("producer lifecycle STATUS consumes existing 50 ms scheduler deadline");break;}
                        if(schedule.phase==2)driver.close();
                        schedule.pause(qpc100ns());haveSteadyStatus=false;lastCompletion=0;lastWriteGap=0;
                        state.phase=schedule.phase;state.phaseEpoch=schedule.phaseEpoch;publish(state);
                    }
                    now=qpc100ns();
                    if(schedule.lifecycleExpired(now)){fail("consumer silence/reconnect lifecycle acknowledgement deadline");break;}
                    if(schedule.resumeDue(now,resumePermit.load())) {
                        if(schedule.phase==3) {
                            if(!connect()){fail("producer reconnect protocol status");break;}
                            ++e.producerReconnects;
                        }
                        bool prefilled=true;for(unsigned i=0;i<3;++i)if(!write(false)){prefilled=false;break;}
                        if(!prefilled){fail("producer resume bounded prefill");break;}
                        schedule.resume(qpc100ns());state.phase=schedule.phase;state.phaseEpoch=schedule.phaseEpoch;
                        haveSteadyStatus=false;publish(state);
                    }
                    now=qpc100ns();
                    if(!schedule.paused()&&now>=schedule.nextWrite) {
                        e.maxLatenessMs=std::max(e.maxLatenessMs,(now-schedule.nextWrite)/10000);
                        if(schedule.schedulerExpired(now)){fail("producer scheduler exceeds existing 50 ms deadline");break;}
                        if(!readStatus(now-schedule.phaseEpoch>=2500000,schedule.began,schedule.nextWrite,schedule.phase)){fail("periodic driver counters, overruns or steady underruns");break;}
                        // STATUS itself can consume the deadline; check again
                        // immediately before the write instead of hiding it.
                        now=qpc100ns();e.maxLatenessMs=std::max(e.maxLatenessMs,(now-schedule.nextWrite)/10000);
                        if(schedule.schedulerExpired(now)){fail("producer IOCTL consumes existing 50 ms scheduler deadline");break;}
                        if(!write(true)){fail("bounded producer write");break;}
                        schedule.nextWrite+=ProducerSchedule::packetPeriod;publish(state);
                    }
                    now=qpc100ns();
                    const uint64_t next=schedule.paused()?now+10000:std::min(schedule.nextWrite,schedule.end);
                    if(next>now) {
                        LARGE_INTEGER due{};due.QuadPart=-static_cast<LONGLONG>(next-now);
                        if(!SetWaitableTimerEx(timer.h,&due,0,nullptr,nullptr,nullptr,0)||WaitForSingleObject(timer.h,200)!=WAIT_OBJECT_0) {
                            fail("producer bounded private timer wait");break;
                        }
                    }
                }
                if(!state.failure&&driver.h!=INVALID_HANDLE_VALUE&&!readStatus(!schedule.paused()&&qpc100ns()-schedule.phaseEpoch>=2500000,
                    schedule.began,schedule.nextWrite,schedule.phase))
                    fail("final driver counters, overruns or steady underruns");
            }
        }
        driver.close();state.done=true;publish(state);finished=true;
    }
};
// This producer only supplies the application's 480-frame upstream callback.
// The actual DriverBridge owns TransferQueue, PCM conversion, IOCTLs and its
// private 2 ms cadence; no lab implementation substitutes for that worker.
struct ProductBridgeProducer {
    ProducerMailbox publication;
    std::atomic<bool> stop{false},finished{false};
    std::atomic<unsigned> resumePermit{0};
    std::thread worker;
    ProductBridgeProducer(unsigned seconds):worker([this,seconds]{run(seconds);}){}
    ProducerPublication snapshot(){return publication.snapshot();}
    void publish(const ProducerPublication& state){if(!publication.publish(state))std::terminate();}
    void finish() {
        stop=true;
        if(worker.joinable()) {
            const uint64_t deadline=GetTickCount64()+1000;
            while(!finished&&GetTickCount64()<deadline)Sleep(1);
            if(!finished){std::puts("Findings product producer shutdown deadline exceeded; process terminates.");std::fflush(stdout);ExitProcess(5);}
            worker.join();
        }
    }
    ~ProductBridgeProducer(){finish();}
    void run(unsigned seconds) {
        ProducerPublication state{};auto& e=state.evidence;e.product=true;e.workerMmcss=true;
        ses::DriverBridge bridge;Handle timer;MmcssAudio mmcss;e.mmcss=mmcss.ready;
        uint64_t baselineReceived=0,baselineSilence=0,sessionSubmitted=0;
        uint64_t previousReceived=0,previousSilence=0;
        uint32_t baselineUnderruns=0,baselineOverruns=0,previousUnderruns=0,previousOverruns=0;
        uint64_t totalReceived=0,totalSilence=0,totalSent=0;
        uint32_t totalUnderruns=0,totalOverruns=0,totalDrops=0;
        bool sessionOpen=false,haveSteady=false;
        std::array<std::array<float,SES_DRIVER_FRAMES>,4> pcm{};
        for(unsigned p=0;p<4;++p)for(unsigned i=0;i<SES_DRIVER_FRAMES;++i)
            pcm[p][i]=static_cast<float>(waveform(p*SES_DRIVER_FRAMES+i));
        auto fail=[&](const char* reason){state.failure=reason;publish(state);};
        auto connect=[&]() {
            bridge.start();const uint64_t deadline=qpc100ns()+2000000;
            while(!stop&&bridge.status!=2&&bridge.status!=6&&qpc100ns()<deadline)Sleep(1);
            e.bridgeStatus=bridge.status.load();e.bridgeLastError=bridge.lastError.load();
            if(stop||bridge.status!=2||bridge.protocol!=SES_DRIVER_PROTOCOL||!bridge.workerMmcss||bridge.queued!=0)return false;
            baselineReceived=previousReceived=bridge.received.load();baselineSilence=previousSilence=bridge.silence.load();
            baselineUnderruns=previousUnderruns=bridge.underruns.load();baselineOverruns=previousOverruns=bridge.overruns.load();
            sessionSubmitted=0;haveSteady=false;sessionOpen=true;++e.sourceSessions;return true;
        };
        auto readStatus=[&](bool steady,uint64_t began,uint64_t due,unsigned phase) {
            const uint64_t sampled=qpc100ns();
            const uint64_t received=bridge.received.load(),quiet=bridge.silence.load(),sent=bridge.sent.load();
            const uint32_t underruns=bridge.underruns.load(),overruns=bridge.overruns.load(),drops=bridge.queueDrops.load();
            const uint32_t queued=bridge.queued.load();const int32_t drift=bridge.drift.load();
            e.workerMmcss=e.workerMmcss&&bridge.workerMmcss.load();
            e.bridgeStatus=bridge.status.load();e.bridgeLastError=bridge.lastError.load();
            const bool valid=e.bridgeStatus==2&&bridge.protocol==SES_DRIVER_PROTOCOL&&e.workerMmcss&&queued<=SES_DRIVER_CAPACITY&&
                drift>=-5005&&drift<=5005&&received>=previousReceived&&quiet>=previousSilence&&
                underruns>=previousUnderruns&&overruns>=previousOverruns&&sent%SES_DRIVER_FRAMES==0;
            if(received<baselineReceived||quiet<baselineSilence||underruns<baselineUnderruns||overruns<baselineOverruns)return false;
            e.writes=(totalSent+sent)/SES_DRIVER_FRAMES;e.queueDrops=totalDrops+drops;
            e.driverReceivedFrames=totalReceived+received-baselineReceived;
            e.driverSilenceFrames=totalSilence+quiet-baselineSilence;
            e.driverUnderruns=totalUnderruns+underruns-baselineUnderruns;
            e.driverOverruns=totalOverruns+overruns-baselineOverruns;
            e.maxWriteGap100ns=std::max(e.maxWriteGap100ns,bridge.maxWriteGap100ns.load());
            e.maxIoctl100ns=std::max(e.maxIoctl100ns,bridge.maxIoctl100ns.load());
            ProducerStatusObservation observation{};observation.sample=++e.statusSamples;
            observation.elapsed100ns=sampled>=began?sampled-began:0;observation.due100ns=due>=began?due-began:0;
            observation.lateness100ns=sampled>=due?sampled-due:0;
            observation.workerPublicationAge100ns=workerPublicationAge(sampled,bridge.statusObserved100ns.load());
            e.maxWorkerPublicationAge100ns=std::max(e.maxWorkerPublicationAge100ns,observation.workerPublicationAge100ns);
            // STATUS timings are unavailable as an isolated operation: this
            // history samples genuine worker counters, with no lab STATUS call.
            const uint64_t completion=bridge.lastWriteCompletion100ns.load();
            observation.lastWriteGap100ns=bridge.lastWriteGap100ns.load();
            observation.sinceWrite100ns=completion&&sampled>=completion?sampled-completion:0;
            observation.phase=phase;observation.steady=steady;observation.queued=queued;observation.drift=drift;
            observation.received=e.driverReceivedFrames;observation.silence=e.driverSilenceFrames;
            observation.underruns=e.driverUnderruns;observation.overruns=e.driverOverruns;
            e.statusHistory.append(observation);
            if(steady){e.minimumQueuedSteady=std::min(e.minimumQueuedSteady,queued);
                if(haveSteady)e.steadyUnderruns+=underruns-previousUnderruns;}
            previousReceived=received;previousSilence=quiet;previousUnderruns=underruns;previousOverruns=overruns;haveSteady=steady;
            return valid&&productTelemetryHealthy(e.bridgeStatus,bridge.protocol.load(),e.workerMmcss,
                e.queueDrops,e.driverOverruns,e.steadyUnderruns);
        };
        auto closeSession=[&](bool steady,uint64_t began,uint64_t due,unsigned phase) {
            // Every accepted callback must reach a successful production WRITE
            // and a later independently observed kernel received counter.
            const uint64_t deadline=qpc100ns()+1500000;
            while(bridge.status==2&&qpc100ns()<deadline&&
                !productDeliveryComplete(sessionSubmitted,bridge.sent.load(),bridge.received.load(),baselineReceived))Sleep(1);
            const bool flushed=productFlushComplete(sessionSubmitted,bridge.sent.load(),bridge.received.load(),baselineReceived,
                qpc100ns(),deadline);
            const bool observed=readStatus(steady,began,due,phase);
            const bool ok=flushed&&observed;
            totalSent=e.writes*SES_DRIVER_FRAMES;
            totalReceived=e.driverReceivedFrames;totalSilence=e.driverSilenceFrames;
            totalUnderruns=e.driverUnderruns;totalOverruns=e.driverOverruns;totalDrops=e.queueDrops;
            bridge.stop();sessionOpen=false;return ok;
        };
        timer.h=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
        if(!timer.h||!mmcss.ready)fail("product upstream private high-resolution timer or MMCSS Pro Audio registration");
        else if(!connect())fail("real DriverBridge initial connection, ownership, protocol or worker MMCSS");
        else {
            ProducerSchedule schedule(qpc100ns(),seconds);state.began=schedule.began;state.ready=true;
            state.phaseEpoch=schedule.phaseEpoch;publish(state);
            while(!stop&&!state.failure&&qpc100ns()<schedule.end) {
                uint64_t now=qpc100ns();
                if(!schedule.paused()&&now>=schedule.nextWrite)e.maxLatenessMs=std::max(e.maxLatenessMs,(now-schedule.nextWrite)/10000);
                if(schedule.schedulerExpired(now)){fail("product upstream exceeds existing 50 ms scheduler deadline");break;}
                if(schedule.pauseAllowed(now)) {
                    if(!closeSession(true,schedule.began,schedule.nextWrite,schedule.phase)){fail("product lifecycle flush, queue drops or real driver counters");break;}
                    now=qpc100ns();
                    if(schedule.schedulerExpired(now)){fail("product lifecycle flush consumes existing 50 ms scheduler deadline");break;}
                    schedule.pause(now);state.phase=schedule.phase;state.phaseEpoch=schedule.phaseEpoch;publish(state);
                }
                now=qpc100ns();
                if(schedule.lifecycleExpired(now)){fail("product consumer silence/reconnect lifecycle acknowledgement deadline");break;}
                if(schedule.resumeDue(now,resumePermit.load())) {
                    if(!connect()){fail("real DriverBridge reconnect, ownership, protocol or worker MMCSS");break;}
                    if(schedule.lifecycleExpired(qpc100ns())){fail("product bridge reconnect exceeds existing lifecycle deadline");break;}
                    if(schedule.phase==3)++e.producerReconnects;
                    schedule.resume(qpc100ns());state.phase=schedule.phase;state.phaseEpoch=schedule.phaseEpoch;publish(state);
                }
                now=qpc100ns();
                if(!schedule.paused()&&now>=schedule.nextWrite) {
                    e.maxLatenessMs=std::max(e.maxLatenessMs,(now-schedule.nextWrite)/10000);
                    if(schedule.schedulerExpired(now)){fail("product upstream deadline before TransferQueue callback");break;}
                    if(!readStatus(now-schedule.phaseEpoch>=2500000,schedule.began,schedule.nextWrite,schedule.phase)) {
                        fail("real DriverBridge counters, worker MMCSS, queue drops or steady underruns");break;}
                    if(e.submittedPackets>=seconds*100ULL+16){fail("product upstream packet count bound");break;}
                    // Counter sampling or preemption must not consume the
                    // callback's deadline and then enqueue expired audio.
                    now=qpc100ns();e.maxLatenessMs=std::max(e.maxLatenessMs,(now-schedule.nextWrite)/10000);
                    if(schedule.schedulerExpired(now)){fail("product counter sampling consumes existing 50 ms scheduler deadline");break;}
                    bridge.push(pcm[sessionSubmitted%4].data());++sessionSubmitted;++e.submittedPackets;
                    schedule.nextWrite+=ProducerSchedule::packetPeriod;publish(state);
                }
                now=qpc100ns();const uint64_t next=schedule.paused()?now+10000:std::min(schedule.nextWrite,schedule.end);
                if(next>now) {
                    LARGE_INTEGER due{};due.QuadPart=-static_cast<LONGLONG>(next-now);
                    if(!SetWaitableTimerEx(timer.h,&due,0,nullptr,nullptr,nullptr,0)||WaitForSingleObject(timer.h,200)!=WAIT_OBJECT_0) {
                        fail("product bounded private upstream timer wait");break;}
                }
            }
            if(sessionOpen&&!state.failure&&!closeSession(!schedule.paused()&&qpc100ns()-schedule.phaseEpoch>=2500000,
                schedule.began,schedule.nextWrite,schedule.phase))fail("product final flush or real driver counters");
        }
        if(sessionOpen) {
            // Failure evidence must retain actual worker values, including any
            // rejected queue/counter sample, before stop clears live state.
            readStatus(false,state.began,qpc100ns(),state.phase);bridge.stop();
        }
        state.done=true;publish(state);finished=true;
    }
};
template<class Producer> bool runExtended(IMMDevice* device,unsigned seconds,Report& r) {
    auto& e=r.extended;e.ran=true;
    const unsigned before=r.failures;
    std::printf("Extended real kernel capture: %u seconds, two PCM32 shared clients in one process.\n",seconds);
    MmcssAudio consumerMmcss;e.consumerMmcss=consumerMmcss.ready;
    r.check(consumerMmcss.ready,"register extended capture consumer with MMCSS Pro Audio priority");
    if(!consumerMmcss.ready)return false;
    ExtendedCapture consumers[2];
    for(auto& consumer:consumers) {
        if(!consumer.open(device)){r.check(false,"start both shared capture clients on verified endpoint");return false;}
    }
    Handle timer;
    timer.h=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_MODIFY_STATE|SYNCHRONIZE);
    if(!timer.h){r.check(false,"extended private high-resolution consumer timer");return false;}
    StreamingAnalyzer analyzer;
    Producer producer(seconds);
    const uint64_t startupDeadline=GetTickCount64()+1000;
    ProducerPublication state=producer.snapshot();
    while(!state.ready&&!state.done&&GetTickCount64()<startupDeadline){Sleep(1);state=producer.snapshot();}
    if(!state.ready){producer.finish();r.check(false,state.failure?state.failure:"producer startup deadline");return false;}
    const uint64_t began=state.began,deadline=began+seconds*10000000ULL;
    uint64_t nextHeartbeat=began+50000000;
    unsigned phase=0,stage=0;bool paused=false,ok=true;
    for(auto& consumer:consumers)consumer.cutoff=state.phaseEpoch+2500000;
    auto abortRun=[&](const char* reason){std::printf("Findings extended capture stopped: %s\n",reason);ok=false;};
    auto copyProducerEvidence=[&](const ExtendedEvidence& source) {
        const auto clients=std::array<ExtendedClientEvidence,2>{e.clients[0],e.clients[1]};
        const bool requested=e.requested,ran=e.ran;const unsigned requestedSeconds=e.requestedSeconds;
        const bool consumerRegistered=e.consumerMmcss;const uint64_t drainGap=e.maxConsumerDrainGap100ns;
        e=source;e.clients[0]=clients[0];e.clients[1]=clients[1];
        e.requested=requested;e.ran=ran;e.requestedSeconds=requestedSeconds;
        e.consumerMmcss=consumerRegistered;e.maxConsumerDrainGap100ns=drainGap;
    };
    while(qpc100ns()<deadline&&ok) {
        state=producer.snapshot();const uint64_t now=qpc100ns();copyProducerEvidence(state.evidence);
        if(state.failure){abortRun(state.failure);break;}
        if(state.done){if(qpc100ns()<deadline)abortRun("producer exited before measured consumer duration");break;}
        if(analyzer.failed){abortRun("periodic waveform fidelity");break;}
        if(state.phase!=phase) {
            phase=state.phase;paused=phase==1||phase==3;stage=phase/2;
            for(auto& consumer:consumers){consumer.signal.clear();consumer.quiet.clear();consumer.cutoff=state.phaseEpoch+2500000;}
            if(phase==3) {
                if(!consumers[1].open(device)){abortRun("second capture client reconnect");break;}
                ++e.clients[1].reconnects;consumers[1].cutoff=std::max(consumers[1].cutoff,qpc100ns()+2500000);
            }
            std::printf("Extended lifecycle: phase=%u actual epoch=%llu ms.\n",phase,
                static_cast<unsigned long long>((state.phaseEpoch-began)/10000));std::fflush(stdout);
        }
        for(unsigned index=0;index<2&&ok;++index) {
            auto& consumer=consumers[index];auto& evidence=e.clients[index];
            const uint64_t drainNow=qpc100ns();
            if(consumer.lastDrain100ns)e.maxConsumerDrainGap100ns=std::max(e.maxConsumerDrainGap100ns,drainNow-consumer.lastDrain100ns);
            consumer.lastDrain100ns=drainNow;
            UINT32 frames=0;unsigned drained=0;
            if(FAILED(consumer.capture->GetNextPacketSize(&frames))){abortRun("capture packet size");break;}
            while(frames&&ok) {
                if(++drained>128){abortRun("capture drain bound");break;}
                BYTE* data=nullptr;DWORD flags=0;UINT64 position=0,stamp=0;
                if(FAILED(consumer.capture->GetBuffer(&data,&frames,&flags,&position,&stamp))){abortRun("capture buffer");break;}
                ++evidence.packets;evidence.frames+=frames;consumer.lastPacketMs=GetTickCount64();
                if(flags&AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY)++evidence.discontinuities;
                if(flags&AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR)++evidence.timestampErrors;
                const bool gap=consumer.hadPacket&&position!=consumer.previousPosition;if(gap)++evidence.gaps;
                bool valid=frames>0&&frames<=rate&&((flags&AUDCLNT_BUFFERFLAGS_SILENT)||data)&&
                    position<=std::numeric_limits<uint64_t>::max()-frames&&stamp<=qpc100ns()+100000&&
                    (!consumer.hadPacket||(position>=consumer.previousPosition&&stamp>consumer.previousStamp));
                // A phase published during this drain is processed next turn,
                // after releasing this COM buffer. Do not enqueue across epochs.
                const bool eligible=stamp>=consumer.cutoff&&producer.snapshot().phase==phase;
                if(eligible) {
                    if(!freshPacket(stamp,consumer.cutoff,flags)||gap)valid=false;
                    if(valid)for(UINT32 i=0;i<frames;++i) {
                        const double value=flags&AUDCLNT_BUFFERFLAGS_SILENT?0:decode(data,32,i);
                        if(paused) {
                            // Every eligible sample must remain silent, including
                            // packets after the required 100 ms observation.
                            if(!std::isfinite(value)||std::abs(value)>1.0/32768.0){valid=false;break;}
                            if(consumer.quiet.size()<minSilenceFrames)consumer.quiet.push_back(value);
                        } else {
                            if(!std::isfinite(value)||std::abs(value)>.35){valid=false;break;}
                            consumer.signal.push_back(value);
                            if(consumer.signal.size()==StreamingAnalyzer::blockFrames&&
                                !analyzer.submit(index,stage,consumer.signal)){valid=false;break;}
                        }
                    }
                }
                const uint64_t expected=consumer.previousPosition,previousStamp=consumer.previousStamp;
                const bool hadPrevious=consumer.hadPacket;
                consumer.previousPosition=position+frames;consumer.previousStamp=stamp;consumer.hadPacket=true;
                if(FAILED(consumer.capture->ReleaseBuffer(frames))){abortRun("release capture buffer");break;}
                if(!valid){
                    std::printf("Extended PCM32 invalid packet: client=%u frames=%u flags=0x%08lx position=%llu expected=%llu stamp=%llu previous=%llu now=%llu had_previous=%s eligible=%s max_consumer_drain_gap_us=%llu\n",
                        index,frames,static_cast<unsigned long>(flags),static_cast<unsigned long long>(position),
                        static_cast<unsigned long long>(expected),static_cast<unsigned long long>(stamp),
                        static_cast<unsigned long long>(previousStamp),static_cast<unsigned long long>(qpc100ns()),
                        hadPrevious?"true":"false",eligible?"true":"false",static_cast<unsigned long long>(e.maxConsumerDrainGap100ns/10));
                    abortRun("buffer, fresh timestamp, continuity or bounded analyzer queue");break;
                }
                if(FAILED(consumer.capture->GetNextPacketSize(&frames))){abortRun("capture drain packet size");break;}
            }
            // A stalled consumer must fail even when the other shared client
            // keeps the driver clock and counters moving normally.
            if(GetTickCount64()-consumer.lastPacketMs>250){abortRun("shared client produced no packet for 250 ms");break;}
        }
        if(!ok)break;
        if(paused&&producer.resumePermit.load()<phase&&lifecycleAcknowledgementExpired(now,state.phaseEpoch)) {
            abortRun("insufficient fresh silence within lifecycle acknowledgement deadline");break;
        }
        if(paused&&producer.resumePermit.load()<phase&&
            silenceObservationReady(now,state.phaseEpoch,consumers[0].quiet.size(),consumers[1].quiet.size())) {
            for(unsigned i=0;i<2;++i) {
                if(!silence(consumers[i].quiet)){abortRun("100 ms fresh silence after actual lifecycle guard");break;}
                ++e.clients[i].silenceChecks;
            }
            if(!ok)break;
            producer.resumePermit=phase;
        }
        if(now>=nextHeartbeat) {
            std::printf("Extended heartbeat: elapsed=%llu/%u000 ms writes=%llu packets=%llu/%llu overruns=%u underruns=%u\n",
                static_cast<unsigned long long>((now-began)/10000),seconds,static_cast<unsigned long long>(e.writes),
                static_cast<unsigned long long>(e.clients[0].packets),static_cast<unsigned long long>(e.clients[1].packets),
                e.driverOverruns,e.driverUnderruns);std::fflush(stdout);nextHeartbeat=now+50000000;
        }
        LARGE_INTEGER due{};due.QuadPart=-10000;
        if(!SetWaitableTimerEx(timer.h,&due,0,nullptr,nullptr,nullptr,0)||WaitForSingleObject(timer.h,200)!=WAIT_OBJECT_0) {
            abortRun("bounded private timer wait");break;
        }
    }
    e.elapsedMs=(qpc100ns()-began)/10000;
    producer.finish();state=producer.snapshot();copyProducerEvidence(state.evidence);
    e.elapsedMs=(qpc100ns()-began)/10000;
    if(state.failure){abortRun(state.failure);}
    std::printf("Extended producer timing: max lateness=%llu ms max write gap=%llu us max IOCTL=%llu us min steady queue=%u frames MMCSS=%s.\n",
        static_cast<unsigned long long>(e.maxLatenessMs),static_cast<unsigned long long>(e.maxWriteGap100ns/10),
        static_cast<unsigned long long>(e.maxIoctl100ns/10),e.minimumQueuedSteady,e.mmcss?"Pro Audio":"failed");
    std::printf("Extended consumer timing: max drain gap=%llu us MMCSS=%s.\n",
        static_cast<unsigned long long>(e.maxConsumerDrainGap100ns/10),e.consumerMmcss?"Pro Audio":"failed");
    r.check(e.driverReceivedFrames==e.writes*SES_DRIVER_FRAMES,
        "driver received-frame counter matches every successful producer packet");
    if(e.product) {
        r.check(e.workerMmcss,"real DriverBridge worker registers MMCSS Pro Audio in every source session");
        r.check(e.queueDrops==0&&e.writes==e.submittedPackets,"every real upstream callback reaches DriverBridge without TransferQueue drops");
        r.check(e.sourceSessions==3,"real DriverBridge stop/start clears stale audio across both lifecycle changes");
    }
    for(auto& consumer:consumers)consumer.close();analyzer.finish();
    r.check(ok&&!analyzer.failed,"extended capture keeps bounded memory, packet integrity, waveform fidelity and driver counters");
    r.check(e.elapsedMs>=seconds*1000ULL&&e.elapsedMs<=seconds*1000ULL+1000,"extended capture completes requested measured duration within bounded shutdown guard");
    for(unsigned i=0;i<2;++i) {
        r.check(e.elapsedMs>1000&&e.clients[i].frames>=(e.elapsedMs-1000)*rate/1000,
            "each shared client captures frames covering measured run apart from bounded startup/reconnect allowance");
        bool allStages=true;
        for(unsigned s=0;s<3;++s){e.clients[i].windows[s]=analyzer.windows[i][s].load();allStages=allStages&&e.clients[i].windows[s]>0;}
        r.check(allStages,"each shared client retains waveform before pause, after resume and after producer reconnect");
        r.check(e.clients[i].silenceChecks==2,"each shared client observes fresh silence for both lifecycle changes");
    }
    r.check(e.producerReconnects==1&&e.clients[1].reconnects==1,"producer and one concurrent consumer reconnect successfully");
    return r.failures==before;
}

struct Options {bool offline=false,lab=false,extended=false,product=false;unsigned seconds=60;const char* reportPath=nullptr;};
bool parseOptions(int argc,char** argv,Options& options) {
    bool durationSet=false;
    for(int i=1;i<argc;++i) {
        if(!std::strcmp(argv[i],"--self-test")&&!options.offline)options.offline=true;
        else if(!std::strcmp(argv[i],"--isolated-lab")&&!options.lab)options.lab=true;
        else if(!std::strcmp(argv[i],"--extended")&&!options.extended)options.extended=true;
        else if(!std::strcmp(argv[i],"--product-bridge")&&!options.product)options.product=true;
        else if(!std::strcmp(argv[i],"--json-report")&&i+1<argc&&!options.reportPath&&argv[i+1][0]&&argv[i+1][0]!='-')options.reportPath=argv[++i];
        else if(!std::strcmp(argv[i],"--duration-seconds")&&i+1<argc&&!durationSet) {
            const char* value=argv[++i];unsigned seconds=0;
            if(!*value)return false;
            for(const char* p=value;*p;++p){if(*p<'0'||*p>'9'||seconds>3600)return false;seconds=seconds*10+static_cast<unsigned>(*p-'0');}
            if(seconds<10||seconds>3600)return false;
            options.seconds=seconds;durationSet=true;
        } else return false;
    }
    return options.offline!=options.lab&&(!options.extended||options.lab)&&(!durationSet||options.extended)&&
        (!options.product||(options.lab&&options.extended&&durationSet));
}
void mailboxSelfTest(Report& r) {
    const char oddFailure[]="fixture odd generation",evenFailure[]="fixture even generation";
    constexpr uint64_t terminal=11002;
    auto makePublication=[&](uint64_t generation) {
        ProducerPublication state{};state.began=generation;state.phaseEpoch=generation*7;state.phase=static_cast<unsigned>(generation%5);
        state.ready=true;state.done=generation==terminal;state.failure=generation%2?oddFailure:evenFailure;
        auto& e=state.evidence;e.writes=generation*11;e.driverReceivedFrames=generation*480;
        e.driverSilenceFrames=generation*13;e.steadyUnderruns=static_cast<uint32_t>(generation%31);
        e.statusHistory.count=64;e.statusHistory.next=0;
        for(size_t i=0;i<64;++i) {
            auto& o=e.statusHistory.observations[i];o.sample=generation;o.elapsed100ns=generation*17+i;
            o.phase=state.phase;o.received=generation*480+i;o.silence=generation*13+i;
            o.underruns=static_cast<uint32_t>(generation%31);o.drift=-static_cast<int32_t>(i);
        }
        return state;
    };
    auto consistent=[&](const ProducerPublication& state) {
        const uint64_t generation=state.began;const auto& e=state.evidence;
        if(!generation||state.phaseEpoch!=generation*7||state.phase!=generation%5||!state.ready||
            state.done!=(generation==terminal)||state.failure!=(generation%2?oddFailure:evenFailure)||
            e.writes!=generation*11||e.driverReceivedFrames!=generation*480||e.driverSilenceFrames!=generation*13||
            e.steadyUnderruns!=generation%31||e.statusHistory.count!=64||e.statusHistory.next!=0)return false;
        for(size_t i=0;i<64;++i) {
            const auto& o=e.statusHistory.observations[i];
            if(o.sample!=generation||o.elapsed100ns!=generation*17+i||o.phase!=state.phase||
                o.received!=generation*480+i||o.silence!=generation*13+i||o.underruns!=generation%31||
                o.drift!=-static_cast<int32_t>(i))return false;
        }
        return true;
    };
    ProducerMailbox mailbox;
    const bool initialized=mailbox.publish(makePublication(1));
    struct ReaderPause {
        std::atomic<bool> held{false},released{false},writerProof{false},timedOut{false};
        uint64_t elapsedMs=0;
    } pause;
    std::atomic<bool> sampling{false},writerDone{false},torn{false},writerFailed{false},barrierTimeout{false};
    uint64_t updatesWhilePinned=0,snapshots=0;
    ProducerPublication pinned;
    std::thread reader([&] {
        pinned=mailbox.snapshot([](void* context) noexcept {
            auto& pause=*static_cast<ReaderPause*>(context);const uint64_t began=GetTickCount64();
            pause.held=true;
            while(GetTickCount64()-began<1000&&(!pause.writerProof||GetTickCount64()-began<40))Sleep(1);
            pause.elapsedMs=GetTickCount64()-began;pause.timedOut=!pause.writerProof||pause.elapsedMs>1000;pause.released=true;
        },&pause);
        if(!consistent(pinned))torn=true;
        sampling=true;
        do {
            if(!consistent(mailbox.snapshot()))torn=true;
            ++snapshots;
        } while(!writerDone);
    });
    const uint64_t heldDeadline=GetTickCount64()+1000;
    while(!pause.held&&GetTickCount64()<heldDeadline)Sleep(1); // Fixture orchestration only.
    if(!pause.held)barrierTimeout=true;
    std::thread writer([&] {
        for(uint64_t generation=2;generation<=1001;++generation) {
            if(!mailbox.publish(makePublication(generation)))writerFailed=true;
            if(!pause.released)++updatesWhilePinned;
        }
        pause.writerProof=true;
        const uint64_t samplingDeadline=GetTickCount64()+1000;
        while(!sampling&&GetTickCount64()<samplingDeadline)Sleep(1);
        if(!sampling){barrierTimeout=true;writerDone=true;return;}
        for(uint64_t generation=1002;generation<=terminal;++generation)
            if(!mailbox.publish(makePublication(generation)))writerFailed=true;
        writerDone=true;
    });
    writer.join();reader.join();
    // With the writer joined, the latest slot is uncontended. This must read
    // the actual final publication, regardless of the reader's prior cache.
    const auto final=mailbox.snapshot();
    auto check=[&](bool ok,const char* label){++r.selfTests;r.check(ok,label);};
    check(initialized&&!writerFailed&&!barrierTimeout&&!pause.timedOut&&pause.elapsedMs>=40&&updatesWhilePinned==1000,
        "three-slot producer publication completes 1000 updates before pinned reader releases after at least 40 ms within bounded fixture guards");
    check(!torn&&pinned.began==1&&snapshots>0,
        "bounded producer mailbox retains unmixed phase, failure, counters and all 64 observations under concurrent copies");
    check(consistent(final)&&final.began==terminal&&final.done,
        "joined producer mailbox delivers actual newest terminal evidence instead of an earlier cached snapshot");
}
void extendedSelfTest(Report& r) {
    mailboxSelfTest(r);
    ++r.selfTests;r.check(workerPublicationAge(100,40)==60&&workerPublicationAge(40,40)==0,
        "worker publication age measures the independent timestamp without changing counter gates");
    ++r.selfTests;r.check(workerPublicationAge(100,0)==0&&workerPublicationAge(40,100)==0&&
        workerPublicationAge(std::numeric_limits<uint64_t>::max(),1)==std::numeric_limits<uint64_t>::max()-1,
        "missing or newer worker timestamp cannot underflow publication age");
    auto check=[&](bool ok,const char* label){++r.selfTests;r.check(ok,label);};
    ProducerStatusHistory history;
    check(history.count==0&&history.next==0&&history.observations.size()==64,
        "producer telemetry starts empty with exactly 64 fixed observations");
    for(uint64_t sample=1;sample<=80;++sample) {
        ProducerStatusObservation observation{};
        observation.sample=sample;observation.elapsed100ns=sample*100000;
        observation.due100ns=sample*100000-1;observation.queued=static_cast<uint32_t>(sample);
        observation.drift=-static_cast<int32_t>(sample);observation.received=sample*480;
        observation.silence=sample==80?22:0;observation.underruns=sample==80?1:0;
        history.append(observation);
    }
    bool chronological=history.count==64&&history.next==16;
    for(size_t i=0;i<history.count;++i) {
        const auto& observation=history.oldest(i);
        chronological=chronological&&observation.sample==i+17&&observation.elapsed100ns==(i+17)*100000&&
            observation.queued==i+17&&observation.drift==-static_cast<int32_t>(i+17)&&observation.received==(i+17)*480;
    }
    check(chronological,"producer telemetry wraps in bounded storage and retains chronological field values");
    ProducerPublication telemetrySnapshot{};telemetrySnapshot.evidence.statusHistory=history;
    const auto& failureObservation=telemetrySnapshot.evidence.statusHistory.oldest(63);
    check(failureObservation.sample==80&&failureObservation.silence==22&&failureObservation.underruns==1,
        "producer publication retains the final counter-failure observation");
    ProducerStatusObservation nextObservation{};nextObservation.sample=81;history.append(nextObservation);
    check(history.count==64&&history.oldest(0).sample==18&&history.oldest(63).sample==81&&
        telemetrySnapshot.evidence.statusHistory.oldest(0).sample==17&&failureObservation.sample==80,
        "producer telemetry publication is an independent consistent snapshot after wrap");
    ProducerSchedule schedule(10000000,12);
    check(!schedule.schedulerExpired(schedule.nextWrite+500000)&&schedule.schedulerExpired(schedule.nextWrite+500001),
        "producer schedule retains exact 50 ms boundary without rounding away a violation");
    check(!schedule.pauseDue(schedule.began+39999999)&&schedule.pauseDue(schedule.began+40000000),
        "producer lifecycle pause begins at one-third of measured QPC duration");
    ProducerSchedule crossing(schedule.began,12);
    const uint64_t pauseBoundary=crossing.began+40000000;
    crossing.nextWrite=pauseBoundary-500001;
    check(crossing.pauseDue(pauseBoundary)&&crossing.schedulerExpired(pauseBoundary)&&!crossing.pauseAllowed(pauseBoundary)&&
        crossing.phase==0&&crossing.phaseEpoch==crossing.began,
        "expired steady scheduler deadline takes priority over a due lifecycle pause without resetting epoch");
    crossing.nextWrite=pauseBoundary-499999;
    check(crossing.pauseAllowed(pauseBoundary)&&!crossing.pauseAllowed(pauseBoundary+2)&&crossing.schedulerExpired(pauseBoundary+2),
        "lifecycle status work crossing exact 50 ms deadline prevents the pending pause");
    schedule.pause(schedule.began+40012345);
    check(!schedule.resumeDue(schedule.phaseEpoch+5500000,0)&&!schedule.resumeDue(schedule.phaseEpoch+5499999,1)&&
        schedule.resumeDue(schedule.phaseEpoch+5500000,1),
        "producer resume requires consumer acknowledgement and full actual 550 ms pause");
    check(!schedule.lifecycleExpired(schedule.phaseEpoch+10000000)&&schedule.lifecycleExpired(schedule.phaseEpoch+10000001),
        "producer lifecycle acknowledgement has a bounded shutdown-safe deadline");
    check(!lifecycleAcknowledgementExpired(schedule.phaseEpoch-1,schedule.phaseEpoch)&&
        !silenceObservationReady(schedule.phaseEpoch-1,schedule.phaseEpoch,4800,4800)&&
        !lifecycleAcknowledgementExpired(schedule.phaseEpoch+10000000,schedule.phaseEpoch)&&
        lifecycleAcknowledgementExpired(schedule.phaseEpoch+10000001,schedule.phaseEpoch),
        "publication newer than sampled clock cannot underflow lifecycle timeout or permit early acknowledgement");
    check(!silenceObservationReady(schedule.phaseEpoch+5000000,schedule.phaseEpoch,4800,4320)&&
        silenceObservationReady(schedule.phaseEpoch+6200000,schedule.phaseEpoch,4800,4800)&&
        schedule.resumeDue(schedule.phaseEpoch+6200000,1)&&!schedule.lifecycleExpired(schedule.phaseEpoch+6200000)&&
        schedule.lifecycleExpired(schedule.phaseEpoch+10000001),
        "late consumer reopen waits for both full fresh silence observations within unchanged one-second lifecycle guard");
    const uint64_t resumed=schedule.phaseEpoch+5500000;schedule.resume(resumed);
    check(schedule.phase==2&&schedule.nextWrite==resumed+100000&&!schedule.schedulerExpired(resumed)&&
        schedule.pauseDue(schedule.began+80000000),
        "resume resets write epoch and preserves independently scheduled second lifecycle");
    // Mock the independent kernel clock while the COM owner is deliberately
    // idle for 28 ms at a time. No endpoint, driver or MMCSS API is accessed.
    ses_driver::PcmRing ring;
    SesDriverHello hello{SES_DRIVER_PROTOCOL,sizeof(hello),rate,1,32,SES_DRIVER_FRAMES};
    bool mockOk=ring.connect(hello,0);uint64_t mockSequence=0;
    auto mockWrite=[&](uint64_t now) {
        SesDriverPacket packet{SES_DRIVER_PROTOCOL,sizeof(packet),SES_DRIVER_FRAMES,0,mockSequence,{}};
        for(unsigned i=0;i<SES_DRIVER_FRAMES;++i)packet.pcm[i]=pcm32(mockSequence*SES_DRIVER_FRAMES+i);
        const bool written=ring.push(packet,now);if(written)++mockSequence;return written;
    };
    for(unsigned i=0;i<3;++i)mockOk=mockWrite(0)&&mockOk;
    ProducerSchedule mockSchedule(0,12);uint64_t consumerTurns=0;
    int32_t pulled[SES_DRIVER_FRAMES]{};
    for(uint64_t ms=1;ms<3000;++ms) {
        const uint64_t now=ms*10000;
        if(now>=mockSchedule.nextWrite){mockOk=mockWrite(ms)&&!mockSchedule.schedulerExpired(now)&&mockOk;mockSchedule.nextWrite+=100000;}
        if(ms%10==0)ring.pull(pulled,SES_DRIVER_FRAMES,32,ms);
        if(ms%28==0)++consumerTurns; // capture work never owns producer cadence
    }
    check(mockOk&&consumerTurns>0&&ring.underruns==0&&ring.overruns==0&&ring.received==mockSequence*SES_DRIVER_FRAMES,
        "mock independent producer preserves exact frames and zero underruns during 28 ms consumer work gaps");
    bool periodic=true;
    for(unsigned i=0;i<SES_DRIVER_FRAMES;++i)periodic=periodic&&std::abs(static_cast<int64_t>(pcm32(i+4*SES_DRIVER_FRAMES))-pcm32(i))<=1;
    check(periodic,"precomputed four-packet waveform retains PCM fidelity across producer sequence cycles");
    auto optionsCheck=[&](std::initializer_list<const char*> args,bool expected,const char* label) {
        std::vector<char*> argv;for(const char* arg:args)argv.push_back(const_cast<char*>(arg));
        Options options;++r.selfTests;r.check(parseOptions(static_cast<int>(argv.size()),argv.data(),options)==expected,label);
    };
    optionsCheck({"test","--isolated-lab","--extended","--duration-seconds","3600"},true,"CLI permits bounded one-hour isolated capture");
    optionsCheck({"test","--self-test","--extended"},false,"CLI rejects active extended capture in offline mode");
    optionsCheck({"test","--isolated-lab","--duration-seconds","60"},false,"CLI rejects duration without explicit extended mode");
    optionsCheck({"test","--isolated-lab","--extended","--duration-seconds","3601"},false,"CLI rejects over-hour duration");
    optionsCheck({"test","--isolated-lab","--extended","--duration-seconds","999999999999999999999"},false,"CLI rejects overflowing duration");
    optionsCheck({"test","--isolated-lab","--extended","--duration-seconds","10junk"},false,"CLI rejects partially numeric duration");
    optionsCheck({"test","--isolated-lab","--extended","--duration-seconds","9"},false,"CLI rejects too-short lifecycle observation");
    optionsCheck({"test","--self-test","--self-test"},false,"CLI rejects duplicate mode flags");
    optionsCheck({"test","--isolated-lab","--extended","--duration-seconds","60","--product-bridge"},true,
        "CLI permits explicit production DriverBridge with bounded extended lab duration");
    optionsCheck({"test","--isolated-lab","--extended","--product-bridge"},false,
        "CLI requires explicit measured duration for production DriverBridge acceptance");
    optionsCheck({"test","--isolated-lab","--product-bridge","--duration-seconds","60"},false,
        "CLI rejects production DriverBridge without extended capture");
    optionsCheck({"test","--self-test","--product-bridge"},false,
        "CLI never activates production DriverBridge on offline self-test");
    optionsCheck({"test","--isolated-lab","--extended","--duration-seconds","60","--product-bridge","--product-bridge"},false,
        "CLI rejects duplicate production DriverBridge flags");
    check(productDeliveryComplete(3,1440,4800,3360)&&!productDeliveryComplete(3,960,4320,3360)&&
        !productDeliveryComplete(3,1440,4320,3360)&&!productDeliveryComplete(3,1440,5280,3360),
        "product terminal gate requires every callback and independent owner-session received-frame delta exactly");
    check(!productDeliveryComplete(1,480,479,480)&&!productDeliveryComplete(1,481,961,480)&&
        !productDeliveryComplete(std::numeric_limits<uint64_t>::max(),480,960,480),
        "product terminal gate rejects counter rollback, partial packets and multiplication overflow");
    check(productFlushComplete(1,480,960,480,1500000,1500000)&&
        !productFlushComplete(1,480,960,480,1500001,1500000)&&
        !productFlushComplete(1,0,480,480,1499999,1500000),
        "product flush rejects late completion past exact 150 ms deadline and pending packets before it");
    check(productTelemetryHealthy(2,SES_DRIVER_PROTOCOL,true,0,0,0)&&
        !productTelemetryHealthy(6,SES_DRIVER_PROTOCOL,true,0,0,0)&&
        !productTelemetryHealthy(2,SES_DRIVER_PROTOCOL+1,true,0,0,0)&&
        !productTelemetryHealthy(2,SES_DRIVER_PROTOCOL,false,0,0,0)&&
        !productTelemetryHealthy(2,SES_DRIVER_PROTOCOL,true,1,0,0)&&
        !productTelemetryHealthy(2,SES_DRIVER_PROTOCOL,true,0,1,0)&&
        !productTelemetryHealthy(2,SES_DRIVER_PROTOCOL,true,0,0,1),
        "product telemetry fails closed for real worker failures, protocol, MMCSS, any queue drop, overrun or steady underrun");
    StreamingAnalyzer analyzer;std::vector<double> first(StreamingAnalyzer::blockFrames),late(first.size());
    for(size_t i=0;i<first.size();++i)first[i]=late[i]=waveform(i+37);
    late[late.size()/2]=std::numeric_limits<double>::quiet_NaN();
    const bool submitted=analyzer.submit(0,0,first)&&analyzer.submit(1,2,late);
    analyzer.finish();++r.selfTests;
    r.check(submitted&&analyzer.windows[0][0]==1&&analyzer.failed,"streaming analyzer detects late corruption after an earlier faithful block");
}
}

int main(int argc,char** argv) {
    Options options;
    if(!parseOptions(argc,argv,options)) {
        std::puts("Usage: ses_driver_capture_lab_tests (--self-test | --isolated-lab [--extended [--duration-seconds 10..3600] [--product-bridge]]) [--json-report path]; --product-bridge requires explicit --extended and --duration-seconds.");return 2;
    }
    Report report;
    report.extended.requested=options.extended;report.extended.requestedSeconds=options.extended?options.seconds:0;
    report.extended.product=options.product;
    if(options.offline){selfTest(report);extendedSelfTest(report);}
    else {
        std::puts("--isolated-lab is an acknowledgement, not isolation. Run only in a dedicated lab.");
        ComApartment apartment;
        report.check(SUCCEEDED(apartment.result),"initialize COM apartment");
        if(SUCCEEDED(apartment.result)) {
            Com<IMMDevice> selected;
            const bool found=findDevice(selected,report);
            report.check(found,"exactly one capture endpoint maps to ROOT\\SES_MICROPHONE and service SesMicrophone");
            if(found){runFormat(selected.p,16,report);runFormat(selected.p,32,report);
                if(options.extended&&report.failures==0&&report.unsupported==0) {
                    if(options.product)runExtended<ProductBridgeProducer>(selected.p,options.seconds,report);
                    else runExtended<ExtendedProducer>(selected.p,options.seconds,report);
                }}
        }
    }
    std::printf("%u checks, %u findings, %u unsupported formats; %u capture formats passed.\n",
        report.checks,report.failures,report.unsupported,report.formatsPassed);
    if(options.reportPath&&!report.json(options.reportPath)){std::puts("Findings JSON report could not be written.");return 1;}
    if(report.failures)return 1;
    if(report.unsupported)return 4; // Incomplete acceptance is never a full pass.
    return 0;
}
