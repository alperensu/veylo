#pragma once
#include <ks.h>
#include <ksmedia.h>
#include "audio_validation.h"
inline bool SesValidateCaptureFormat(PKSDATAFORMAT format) {
    if(!format||format->FormatSize<82||format->FormatSize>104||
       !IsEqualGUIDAligned(format->MajorFormat,KSDATAFORMAT_TYPE_AUDIO)||
       !IsEqualGUIDAligned(format->SubFormat,KSDATAFORMAT_SUBTYPE_PCM)||
       !IsEqualGUIDAligned(format->Specifier,KSDATAFORMAT_SPECIFIER_WAVEFORMATEX))return false;
    const auto* wave=reinterpret_cast<const WAVEFORMATEX*>(format+1);
    const ses_driver::PcmFormat fields{format->FormatSize,wave->wFormatTag,wave->nChannels,
        wave->nSamplesPerSec,wave->nAvgBytesPerSec,wave->nBlockAlign,wave->wBitsPerSample,wave->cbSize};
    if(!ses_driver::validCaptureFormat(fields))return false;
    if(wave->wFormatTag==WAVE_FORMAT_EXTENSIBLE){
        const auto* ext=reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wave);
        return ext->Samples.wValidBitsPerSample==wave->wBitsPerSample&&
            ext->dwChannelMask==KSAUDIO_SPEAKER_MONO&&IsEqualGUIDAligned(ext->SubFormat,KSDATAFORMAT_SUBTYPE_PCM);
    }
    return true;
}
