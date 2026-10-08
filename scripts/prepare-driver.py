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
    p=target/file;p.write_text(transform(p.read_text(encoding='utf-8-sig')),encoding='utf-8')
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
    s=s.replace('#include <sysvad.h>','#include <sysvad.h>\n#include "bridge.h"')
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
    return s
edit('EndpointsCommon/minwavertstream.cpp',stream)
edit('EndpointsCommon/minwavertstream.h',lambda s:s.replace('#include "tonegenerator.h"','').replace('    ToneGenerator               m_ToneGenerator;',''))
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
    s=s.replace('    return ntStatus;\n} // StartDevice','    if(NT_SUCCESS(ntStatus))SesBridgeOnline(TRUE);\n    return ntStatus;\n} // StartDevice')
    s=s.replace('    case IRP_MN_STOP_DEVICE:\n','    case IRP_MN_STOP_DEVICE:\n        SesBridgeOnline(FALSE);\n')
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

