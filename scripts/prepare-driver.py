"""Reproducible Veylo adaptation of the pinned MIT SYSVAD sources (no installation)."""
from pathlib import Path
import hashlib,json,shutil,re
root=Path(__file__).resolve().parent.parent
source=root/'driver/upstream/sysvad'
lock=json.loads((root/'driver/upstream.lock.json').read_text(encoding='utf-8'))
for file,digest in lock['files'].items():
    if hashlib.sha256((source/file).read_bytes()).hexdigest()!=digest:raise SystemExit('SYSVAD checksum mismatch: '+file)
target=root/'build/driver/sysvad'
shutil.copytree(source,target,dirs_exist_ok=True)
def edit(file,transform):
    p=target/file;original=p.read_text(encoding='utf-8-sig');adapted=transform(original)
    if adapted==original:raise SystemExit('Required adaptation made no change: '+file)
    p.write_text(adapted,encoding='utf-8')
def replace_required(s,old,new,count=1):
    if s.count(old)!=count:raise SystemExit('Unexpected SYSVAD transform anchor: '+old[:90])
    return s.replace(old,new)
def pairs(s):
    begin=s.index('static\nENDPOINT_MINIPAIR MicInMiniports')
    end=s.index('/*********************************************************************',begin)
    mic=s[begin:end]
    return '''// Adapted from Microsoft SYSVAD. Copyright (c) Microsoft Corporation.
#pragma once
#include "micintopo.h"
#include "micintoptable.h"
#include "micinwavtable.h"
NTSTATUS CreateMiniportWaveRTSYSVAD(PUNKNOWN*,REFCLSID,PUNKNOWN,POOL_FLAGS,PUNKNOWN,PVOID,PENDPOINT_MINIPAIR);
NTSTATUS CreateMiniportTopologySYSVAD(PUNKNOWN*,REFCLSID,PUNKNOWN,POOL_FLAGS,PUNKNOWN,PVOID,PENDPOINT_MINIPAIR);
static PHYSICALCONNECTIONTABLE MicInTopologyPhysicalConnections[]={{KSPIN_TOPO_BRIDGE,KSPIN_WAVE_BRIDGE,CONNECTIONTYPE_TOPOLOGY_OUTPUT}};
'''+mic+'''
static PENDPOINT_MINIPAIR g_RenderEndpoints[]={nullptr};
#define g_cRenderEndpoints 0
static PENDPOINT_MINIPAIR g_CaptureEndpoints[]={&MicInMiniports};
#define g_cCaptureEndpoints 1
#define g_MaxMiniports 2
'''
edit('TabletAudioSample/minipairs.h',pairs)
def formats(s):
    s=s.replace('MICIN_MAX_BITS_PER_SAMPLE_PCM       16','MICIN_MAX_BITS_PER_SAMPLE_PCM       32').replace('MICIN_MIN_SAMPLE_RATE               8000','MICIN_MIN_SAMPLE_RATE               48000').replace('MICIN_MAX_INPUT_STREAMS             5','MICIN_MAX_INPUT_STREAMS             1')
    begin=s.index('KSDATAFORMAT_WAVEFORMATEXTENSIBLE MicInPinSupportedDeviceFormats[]')
    end=s.index('//\n// Supported modes',begin)
    def format(bits):return '{ {sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE),0,0,0,STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM),STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX)}, {{WAVE_FORMAT_EXTENSIBLE,1,48000,'+str(48000*bits//8)+','+str(bits//8)+','+str(bits)+',sizeof(WAVEFORMATEXTENSIBLE)-sizeof(WAVEFORMATEX)},'+str(bits)+',KSAUDIO_SPEAKER_MONO,STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM)} }'
    s=s[:begin]+'KSDATAFORMAT_WAVEFORMATEXTENSIBLE MicInPinSupportedDeviceFormats[]={'+format(16)+','+format(32)+'};\n\n'+s[end:]
    s=s.replace('MicInPinSupportedDeviceFormats[2]','MicInPinSupportedDeviceFormats[1]').replace('MicInPinSupportedDeviceFormats[4]','MicInPinSupportedDeviceFormats[1]')
    return s
edit('TabletAudioSample/micinwavtable.h',formats)
def stream(s):
    s=replace_required(s,'#include <sysvad.h>','#include <sysvad.h>\n#include "bridge.h"\n#include "format_validation.h"')
    s=replace_required(s,'    pWfEx = GetWaveFormatEx(DataFormat_);','    if(!SesValidateCaptureFormat(DataFormat_))return STATUS_INVALID_PARAMETER;\n    pWfEx = GetWaveFormatEx(DataFormat_);')
    # Cancel/wait BEFORE releasing anything the notification callback uses.
    a=s.index('    if (m_pNotificationTimer)')
    b=s.index('    KeFlushQueuedDpcs();',a)+len('    KeFlushQueuedDpcs();')
    timer_cleanup=s[a:b];s=s[:a]+s[b:]
    s=replace_required(s,'    PAGED_CODE();\n    if (NULL != m_pMiniport)','    PAGED_CODE();\n'+timer_cleanup+'\n    if (NULL != m_pMiniport)')
    s=replace_required(s,'    m_pDmaBuffer = (BYTE*)m_pPortStream->MapAllocatedPages(pBufferMdl, MmCached);','    m_pDmaBuffer = (BYTE*)m_pPortStream->MapAllocatedPages(pBufferMdl, MmCached);\n    if(!m_pDmaBuffer){m_pPortStream->FreePagesFromMdl(pBufferMdl);return STATUS_INSUFFICIENT_RESOURCES;}',2)
    s=replace_required(s,'    ulBufferDurationMs = (RequestedSize_ * 1000) / m_ulDmaMovementRate;','    ulBufferDurationMs = static_cast<ULONG>((static_cast<ULONGLONG>(RequestedSize_) * 1000) / m_ulDmaMovementRate);')
    s=replace_required(s,'    if ((NotificationCount_ == 0) || (RequestedSize_ % NotificationCount_ != 0))','    if (!ses_driver::validNotificationBuffer(RequestedSize_,NotificationCount_,m_pWfExt->Format.nBlockAlign))')
    # Private complete packets are retained independently of the OS DMA slots.
    # Allocate only while the stream is stopped, never in the streaming path.
    a=s.index('NTSTATUS CMiniportWaveRTStream::AllocateBufferWithNotification')
    b=s.index('VOID CMiniportWaveRTStream::FreeBufferWithNotification',a)
    allocation=s[a:b]
    allocation=replace_required(allocation,'    RequestedSize_ -= RequestedSize_ % (m_pWfExt->Format.nBlockAlign);','''    if(m_pCaptureStorage||m_pDmaBuffer)return STATUS_INVALID_DEVICE_STATE;
    const ULONG packetBytes=RequestedSize_/NotificationCount_;
    if(packetBytes>ses_driver::CapturePackets::MaxPacketBytes)return STATUS_INVALID_PARAMETER;
    RequestedSize_ -= RequestedSize_ % (m_pWfExt->Format.nBlockAlign);''')
    allocation=replace_required(allocation,'    m_ulNotificationsPerBuffer = NotificationCount_;','''    const ULONG storageBytes=packetBytes*ses_driver::CapturePackets::StorageSlots;
    m_pCaptureStorage=static_cast<BYTE*>(ExAllocatePool2(POOL_FLAG_NON_PAGED,storageBytes,MINWAVERTSTREAM_POOLTAG));
    if(!m_pCaptureStorage||!m_capturePackets.configure(m_pCaptureStorage,storageBytes,packetBytes,m_pWfExt->Format.nBlockAlign)){
        if(m_pCaptureStorage){ExFreePoolWithTag(m_pCaptureStorage,MINWAVERTSTREAM_POOLTAG);m_pCaptureStorage=nullptr;}
        m_pPortStream->UnmapAllocatedPages(m_pDmaBuffer,pBufferMdl);m_pDmaBuffer=nullptr;
        m_pPortStream->FreePagesFromMdl(pBufferMdl);return STATUS_INSUFFICIENT_RESOURCES;
    }
    RtlZeroMemory(m_pDmaBuffer,RequestedSize_);
    m_ulNotificationsPerBuffer = NotificationCount_;''')
    s=s[:a]+allocation+s[b:]
    s=replace_required(s,'    m_ulNotificationsPerBuffer = 0;\n\n    return;','''    m_ulNotificationsPerBuffer = 0;
    m_capturePackets=ses_driver::CapturePackets{};
    if(m_pCaptureStorage){ExFreePoolWithTag(m_pCaptureStorage,MINWAVERTSTREAM_POOLTAG);m_pCaptureStorage=nullptr;}

    return;''')
    s=replace_required(s,'    if (NULL != m_pMiniport)','    if(m_pCaptureStorage){ExFreePoolWithTag(m_pCaptureStorage,MINWAVERTSTREAM_POOLTAG);m_pCaptureStorage=nullptr;}\n    if (NULL != m_pMiniport)',1)
    s=replace_required(s,'            m_llPacketCounter = 0;','''            m_llPacketCounter = 0;
            m_capturePackets.reset();
            m_captureGeneration=SesBridgeGeneration();
            m_byteDisplacementCarryForward=0;
            m_hnsElapsedTimeCarryForward=0;
            m_hnsDPCTimeCarryForward=0;''')
    begin=s.index('    if (m_bCapture)\n    {\n        ReadRegistrySettings();')
    end=s.index('    else if (!g_DoNotCreateDataFiles)',begin)
    s=s[:begin]+'''    if (m_bCapture)
    {
        if(m_pWfExt->Format.nSamplesPerSec!=48000||m_pWfExt->Format.nChannels!=1||
           !(m_pWfExt->Format.wBitsPerSample==16||m_pWfExt->Format.wBitsPerSample==32))return STATUS_INVALID_PARAMETER;
    }
'''+s[end:]
    s=s.replace('m_ToneGenerator.GenerateSine(m_pDmaBuffer + bufferOffset, runWrite);','SesBridgeCapture(m_pDmaBuffer + bufferOffset, runWrite, m_pWfExt->Format.wBitsPerSample);')
    # A long suspend interval must not run a huge DPC loop or deliver stale data.
    s=s.replace('    ULONG bufferOffset = m_ullLinearPosition % m_ulDmaBufferSize;','''    if(!m_ulDmaBufferSize)return;
    if(ByteDisplacement>m_ulDmaBufferSize){RtlZeroMemory(m_pDmaBuffer,m_ulDmaBufferSize);return;}
    ULONG bufferOffset = m_ullLinearPosition % m_ulDmaBufferSize;''')
    a=s.index('    ULONG TimeElapsedInMS = (ULONG)(hnsCurrentTime - m_ullDmaTimeStamp')
    b=s.index('    // Increment presentation position',a)
    s=s[:a]+'''    if(!m_ulDmaBufferSize||!m_pDmaBuffer)return;
    const uint64_t elapsed=ses_driver::elapsedHns(static_cast<uint64_t>(hnsCurrentTime),static_cast<uint64_t>(m_ullDmaTimeStamp));
    const auto movement=ses_driver::advancePcm(elapsed,m_pWfExt->Format.nBlockAlign,m_byteDisplacementCarryForward);
    m_byteDisplacementCarryForward=movement.fraction;
    m_hnsElapsedTimeCarryForward=movement.fraction/SES_DRIVER_RATE;
    ULONGLONG ByteDisplacement=movement.bytes;

'''+s[b:]
    s=replace_required(s,'    _In_ ULONG ByteDisplacement','    _In_ ULONGLONG ByteDisplacement',2)
    s=replace_required(s,'ULONG runWrite = min(ByteDisplacement, m_ulDmaBufferSize - bufferOffset);','ULONG runWrite = static_cast<ULONG>(min(ByteDisplacement, static_cast<ULONGLONG>(m_ulDmaBufferSize - bufferOffset)));',2)
    a=s.index('    ULONG TimeElapsedInMS = (ULONG)(hnsCurrentTime - _this->m_ullLastDPCTimeStamp')
    b=s.index('    if (!bufferCompleted',a)
    s=s[:a]+'''    const uint64_t elapsed=ses_driver::elapsedHns(static_cast<uint64_t>(hnsCurrentTime),static_cast<uint64_t>(_this->m_ullLastDPCTimeStamp),static_cast<uint64_t>(_this->m_hnsDPCTimeCarryForward));
    const uint64_t interval=static_cast<uint64_t>(_this->m_ulNotificationIntervalMs)*10000;
    uint64_t completedIntervals=0;
    if(interval&&elapsed>=interval){
        completedIntervals=elapsed/interval;
        _this->m_hnsDPCTimeCarryForward=elapsed%interval;
        _this->m_ullLastDPCTimeStamp=hnsCurrentTime;
        bufferCompleted=TRUE;
    }

'''+s[b:]
    s=replace_required(s,'        _this->m_llPacketCounter++;','        _this->m_llPacketCounter+=static_cast<LONGLONG>(completedIntervals);')
    # DMA progress must follow the 1ms emulation clock even when a client asks
    # for a much larger notification period; otherwise the producer stalls.
    s=replace_required(s,'    _this->UpdatePosition(qpc);','')
    s=replace_required(s,'    if (!bufferCompleted && !_this->m_bEoSReceived)','    _this->UpdatePosition(qpc);\n    if (!bufferCompleted && !_this->m_bEoSReceived)')
    # The completion clock must describe actual assembled PCM packets. Multiple
    # completions wake the OS once; MoreData lets it drain every retained packet.
    s=replace_required(s,'    _this->UpdatePosition(qpc);\n    if (!bufferCompleted', '''    _this->UpdatePosition(qpc);
    if(_this->m_bCapture&&_this->m_ulNotificationsPerBuffer){
        const uint64_t completed=_this->m_capturePackets.completedPackets();
        bufferCompleted=completed>static_cast<uint64_t>(_this->m_llPacketCounter);
        _this->m_llPacketCounter=static_cast<LONGLONG>(completed);
    }
    if (!bufferCompleted''')
    s=replace_required(s,'    if (!_this->m_bEoSReceived)\n    {\n        _this->m_llPacketCounter+=static_cast<LONGLONG>(completedIntervals);','    if (!_this->m_bCapture && !_this->m_bEoSReceived)\n    {\n        _this->m_llPacketCounter+=static_cast<LONGLONG>(completedIntervals);')
    a=s.index('    KIRQL oldIrql;',s.index('NTSTATUS CMiniportWaveRTStream::GetReadPacket'))
    b=s.index('\n    return STATUS_SUCCESS;',a)
    s=s[:a]+'''    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock,&oldIrql);
    const uint64_t generation=SesBridgeGeneration();
    if(generation!=m_captureGeneration){m_capturePackets.discard();m_captureGeneration=generation;}
    const auto packet=m_capturePackets.peek();
    uint64_t firstSampleQpc=0;
    NTSTATUS result=STATUS_DEVICE_NOT_READY;
    if(packet.data&&m_pDmaBuffer&&m_ulNotificationsPerBuffer&&m_capturePackets.packetBytes()){
        if(!ses_driver::hnsToQpc(packet.startHns,
            static_cast<uint64_t>(m_ullPerformanceCounterFrequency.QuadPart),firstSampleQpc)){
            result=STATUS_INVALID_DEVICE_STATE;
        }else{
            // GetReadPacket acknowledges the previous read. Only this routine
            // publishes complete PCM to DMA; timer progress cannot overwrite it.
            const ULONG offset=(static_cast<ULONG>(packet.number)%m_ulNotificationsPerBuffer)*m_capturePackets.packetBytes();
            if(SesBridgePublish(m_captureGeneration,m_pDmaBuffer+offset,packet.data,m_capturePackets.packetBytes())&&m_capturePackets.consume(packet.number)){
                *PacketNumber=static_cast<ULONG>(packet.number);
                *PerformanceCounterValue=firstSampleQpc;*Flags=0;*MoreData=packet.moreData;
                m_ulLastOsReadPacket=*PacketNumber;result=STATUS_SUCCESS;
            }else result=STATUS_INVALID_DEVICE_STATE;
        }
    }
    KeReleaseSpinLock(&m_PositionSpinLock,oldIrql);
    return result;'''+s[b+len('\n    return STATUS_SUCCESS;'):]
    s=replace_required(s,'    ULONG availablePacketNumber;\n    ULONG droppedPackets;','')
    # Assemble into private bounded storage. In notification mode DMA remains
    # unchanged until the OS explicitly asks for the next complete packet.
    a=s.index('    if(!m_ulDmaBufferSize)return;',s.index('VOID CMiniportWaveRTStream::WriteBytes'))
    s=s[:a]+'''    if(m_ulNotificationsPerBuffer){
        const ULONG packetBytes=m_capturePackets.packetBytes();
        if(!packetBytes)return;
        const uint64_t generation=SesBridgeGeneration();
        if(generation!=m_captureGeneration){m_capturePackets.discard();m_captureGeneration=generation;}
        const uint64_t finalLinear=m_ullLinearPosition+ByteDisplacement;
        // At most eight packet spans are produced per update, even after a
        // long suspension. A skipped interval stays visible as a position gap.
        if(ByteDisplacement>static_cast<ULONGLONG>(packetBytes)*ses_driver::CapturePackets::Capacity){
            m_capturePackets.skipTo(m_ullLinearPosition+ByteDisplacement);return;
        }
        while(ByteDisplacement){
            const auto span=m_capturePackets.writeSpan();
            if(!span.data||!span.bytes)return;
            const ULONG bytes=static_cast<ULONG>(min(ByteDisplacement,static_cast<ULONGLONG>(span.bytes)));
            uint64_t firstSampleHns=0;
            if(!ses_driver::capturePacketStartHns(m_capturePackets.completedPackets()+1,
                finalLinear,m_hnsElapsedTimeCarryForward,m_captureUpdateHns,packetBytes,
                m_ulDmaMovementRate,firstSampleHns))return;
            SesBridgeCapture(span.data,bytes,m_pWfExt->Format.wBitsPerSample,m_captureGeneration);
            if(!m_capturePackets.commit(bytes,firstSampleHns))return;
            ByteDisplacement-=bytes;
        }
        return;
    }
'''+s[a:]
    s=replace_required(s,'        WriteBytes(ByteDisplacement);','        m_captureUpdateHns=static_cast<uint64_t>(hnsCurrentTime);\n        WriteBytes(ByteDisplacement);')
    return s
edit('EndpointsCommon/minwavertstream.cpp',stream)
edit('EndpointsCommon/minwavertstream.h',lambda s:s.replace('#include "tonegenerator.h"','#include "capture_packets.h"').replace('    ToneGenerator               m_ToneGenerator;','    BYTE* m_pCaptureStorage{};\n    uint64_t m_captureGeneration{},m_captureUpdateHns{};\n    ses_driver::CapturePackets m_capturePackets{};').replace('_In_ ULONG ByteDisplacement','_In_ ULONGLONG ByteDisplacement'))
edit('EndpointsCommon/MiniportStreamAudioEngineNode.cpp',lambda s:s.replace('m_ToneGenerator.SetMute(protectionOption == CONSTRICTOR_OPTION_MUTE);','UNREFERENCED_PARAMETER(protectionOption);'))
def no_sideband(s):
    # Upstream's engine-node methods have sideband branches outside feature guards.
    # Keep their complete ordinary-device branches, removing unavailable sideband code.
    while True:
        match=re.search(r'if\s*\(IsSidebandDevice\(\).*?\)\s*\{',s)
        if not match:return s
        brace=s.index('{',match.start());depth=1;i=brace+1
        while depth:
            if s[i]=='{':depth+=1
            elif s[i]=='}':depth-=1
            i+=1
        tail=re.match(r'\s*else\s*',s[i:])
        end=i+tail.end() if tail else i
        s=s[:match.start()]+s[end:]
edit('EndpointsCommon/MiniportAudioEngineNode.cpp',no_sideband)
def adapter(s):
    s=s.replace('#include <sysvad.h>','#include <sysvad.h>\n#include "bridge.h"')
    s=s.replace('    ReleaseRegistryStringBuffer();\n\n    if (DriverObject == NULL)','    SesBridgeShutdown();\n    ReleaseRegistryStringBuffer();\n\n    if (DriverObject == NULL)',1)
    s=s.replace('    ntStatus = STATUS_SUCCESS;\n    \nDone:', '    ntStatus = SesBridgeInitialize(DriverObject);\n    \nDone:',1)
    s=replace_required(s,'    ntStatus = NewAdapterCommon(','    ntStatus = SesBridgeStart(DeviceObject);\n    IF_FAILED_JUMP(ntStatus, Exit);\n    ntStatus = NewAdapterCommon(')
    s=replace_required(s,'    return ntStatus;\n} // StartDevice','    SesBridgeOnline(DeviceObject,NT_SUCCESS(ntStatus));\n    return ntStatus;\n} // StartDevice')
    s=replace_required(s,'    case IRP_MN_STOP_DEVICE:\n','    case IRP_MN_STOP_DEVICE:\n        if(stack->MinorFunction==IRP_MN_REMOVE_DEVICE)SesBridgeRemove(_DeviceObject);\n        else SesBridgeOnline(_DeviceObject,FALSE);\n')
    # Remove SYSVAD's demonstration registration of the calling thread as a
    # streaming resource. SES has no driver-owned streaming thread to register.
    a=s.index('        //\n        // Test: add and remove current thread as streaming audio resource.')
    b=s.index('    }\n\n    SAFE_RELEASE(unknownTopology);',a)
    s=s[:a]+s[b:]
    s=re.sub(r'^.*pPortClsResMgr2?\s*=\s*NULL;\n','',s,flags=re.M)
    begin=s.index('InstallAllRenderFilters(')
    a=s.index('{',begin);depth=1;i=a+1
    while depth:
        if s[i]=='{':depth+=1
        elif s[i]=='}':depth-=1
        i+=1
    s=s[:a]+"{ PAGED_CODE();UNREFERENCED_PARAMETER(_pDeviceObject);UNREFERENCED_PARAMETER(_pIrp);UNREFERENCED_PARAMETER(_pAdapterCommon);return STATUS_SUCCESS;}"+s[i:]
    return s
edit('adapter.cpp',adapter)
def registry(s):
    # Upstream checked the old allocation rather than the new name allocation.
    s=re.sub(r'(pwstrKeyValueName = \(PWSTR\)ExAllocatePool2[^;]+;\s*)IF_TRUE_ACTION_JUMP\(kvFullInfo == NULL',r'\1IF_TRUE_ACTION_JUMP(pwstrKeyValueName == NULL',s)
    s=re.sub(r'(pwstrKeyName = \(PWSTR\)ExAllocatePool2[^;]+;\s*)IF_TRUE_ACTION_JUMP\(kBasicInfo == NULL',r'\1IF_TRUE_ACTION_JUMP(pwstrKeyName == NULL',s)
    s=s.replace('PWSTR pwstrKeyValueName;','PWSTR pwstrKeyValueName = NULL;').replace('PWSTR pwstrKeyName;','PWSTR pwstrKeyName = NULL;')
    s=s.replace('ExFreePoolWithTag(pwstrKeyValueName, MINADAPTER_POOLTAG);','ExFreePoolWithTag(pwstrKeyValueName, MINADAPTER_POOLTAG);pwstrKeyValueName = NULL;')
    s=s.replace('ExFreePoolWithTag(pwstrKeyName, MINADAPTER_POOLTAG);','ExFreePoolWithTag(pwstrKeyName, MINADAPTER_POOLTAG);pwstrKeyName = NULL;')
    s=s.replace('    // Open the template device interface\'s registry key path','    IF_FAILED_JUMP(ntStatus, Exit);\n    // Open the template device interface\'s registry key path')
    return s
edit('common.cpp',registry)
def modules(s):
    s=s.replace('    ULONG cbMinSize = ParameterInfo->Size;','    if(!CurrentValue||ParameterInfo->Size==0)return STATUS_INVALID_PARAMETER;\n    ULONG cbMinSize = ParameterInfo->Size;')
    s=s.replace('    else if (*BufferCb >= (sizeof(KSPROPERTY_DESCRIPTION)))','    else if (!Buffer) return STATUS_INVALID_PARAMETER;\n    else if (*BufferCb >= (sizeof(KSPROPERTY_DESCRIPTION)))')
    s=s.replace('        else\n        {\n            RtlCopyMemory(OutBuffer,','        else\n        {\n            if(!OutBuffer)return STATUS_INVALID_PARAMETER;\n            RtlCopyMemory(OutBuffer,')
    s=s.replace('        if (!IsAudioModuleParameterValid(ParameterInfo, InBuffer, InBufferCb))','        if (!InBuffer || !IsAudioModuleParameterValid(ParameterInfo, InBuffer, InBufferCb))')
    s=s.replace('if (BufferCb < ParameterInfo->Size)','if (ParameterInfo->Size==0||BufferCb < ParameterInfo->Size)')
    s=s.replace('j < ParameterInfo->Size','j < ParameterInfo->Size && j < BufferCb').replace('i < ParameterInfo->Size','i < ParameterInfo->Size && i < BufferCb')
    return s
edit('EndpointsCommon/AudioModuleHelper.cpp',modules)
def no_kernel_modules(s):
    s=replace_required(s,'#include <sysvad.h>','#include <sysvad.h>\n#include "format_validation.h"')
    s=replace_required(s,'    *OutStream = NULL;','    *OutStream = NULL;\n    if(!SesValidateCaptureFormat(DataFormat))return STATUS_INVALID_PARAMETER;')
    s=replace_required(s,'    cPinFormats = GetPinSupportedDeviceFormats(_ulPin, &pPinFormats);','    if(!SesValidateCaptureFormat(_pDataFormat))return STATUS_NO_MATCH;\n    cPinFormats = GetPinSupportedDeviceFormats(_ulPin, &pPinFormats);')
    s=replace_required(s,'if (pFormat->DataFormat.FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEX))','if (_pDataFormat->FormatSize < sizeof(KSDATAFORMAT) + sizeof(WAVEFORMATEX))')
    begin=s.index('    ULONG cModules = GetAudioModuleListCount();')
    end=s.index('    //\n    // Init the audio-engine used by the render devices.',begin)
    s=s[:begin]+'    if(GetAudioModuleListCount()!=0)return STATUS_NOT_SUPPORTED;\n\n'+s[end:]
    s=s.replace('    size = cModules * sizeof(AUDIOMODULE);','    if(cModules>MAXULONG/sizeof(AUDIOMODULE))return STATUS_INVALID_PARAMETER;\n    size = cModules * sizeof(AUDIOMODULE);')
    return s
edit('EndpointsCommon/minwavert.cpp',no_kernel_modules)
edit('EndpointsCommon/NewDelete.cpp',lambda s:s.replace('ExAllocatePool2(poolFlags,','ExAllocatePool2(POOL_FLAG_NON_PAGED,').replace('    PVOID result = ExAllocatePool2','    UNREFERENCED_PARAMETER(poolFlags);\n    PVOID result = ExAllocatePool2'))
for header in ['EndpointsCommon/minwavert.h','EndpointsCommon/minwavertstream.h','common.cpp','savedata.h']:
    edit(header,lambda s:re.sub(r'^(?!\s*(?:return|delete|goto|throw)\b)(\s*[\w:*]+\s+\*?\s*m_\w+(?:\[[^\]\n]+\])?)\s*;',r'\1{};',s,flags=re.M))
edit('TabletAudioSample/micintoptable.h',lambda s:s.replace('ePortConnJack,','ePortConnIntegratedDevice,'))
print('Verified and adapted',len(lock['files']),'SYSVAD files; one capture endpoint, no render endpoints')
