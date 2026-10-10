#pragma once
#ifdef _KERNEL_MODE
typedef LONG int32_t;
typedef SHORT int16_t;
typedef ULONG uint32_t;
typedef ULONGLONG uint64_t;
typedef LONGLONG int64_t;
#else
#include <stdint.h>
#endif
/* Fixed-width, pointer-free, METHOD_BUFFERED wire protocol. No voice is persisted. */
#define SES_DRIVER_PROTOCOL 1u
#define SES_DRIVER_RATE 48000u
#define SES_DRIVER_FRAMES 480u
#define SES_DRIVER_CAPACITY 4096u
#define SES_DRIVER_TARGET 480u
#define SES_DRIVER_TIMEOUT_MS 100u
#define SES_DRIVER_PATH L"\\\\.\\SesMicrophone"
#define SES_DRIVER_HARDWARE_ID L"ROOT\\SES_MICROPHONE"
#define SES_DRIVER_DEVICE_TYPE 0x8337u
#define SES_DRIVER_IOCTL(n) ((SES_DRIVER_DEVICE_TYPE<<16)|(3u<<14)|((n)<<2))
#define SES_IOCTL_CONNECT SES_DRIVER_IOCTL(0x800u)
#define SES_IOCTL_WRITE SES_DRIVER_IOCTL(0x801u)
#define SES_IOCTL_STATUS SES_DRIVER_IOCTL(0x802u)
#define SES_IOCTL_DIAGNOSTICS SES_DRIVER_IOCTL(0x803u)
#define SES_DRIVER_DIAGNOSTICS_VERSION 1u
#pragma pack(push, 8)
typedef struct SesDriverHello { uint32_t version,size,rate,channels,bits,frames; } SesDriverHello;
typedef struct SesDriverPacket {
    uint32_t version,size,frames,reserved;
    uint64_t sequence;
    int32_t pcm[SES_DRIVER_FRAMES];
} SesDriverPacket;
typedef struct SesDriverStatus {
    uint32_t version,size,connected,queued_frames;
    uint64_t received_frames,silence_frames;
    uint32_t underruns,overruns;
    int32_t drift_ppm;
    uint32_t reserved;
} SesDriverStatus;
/* Additive diagnostics; protocol 1 audio/status layouts remain unchanged.
   Ticks and gaps use KeQueryInterruptTime's 100ns units, never QPC units.
   Capture counters cover attached calls since the last successful CONNECT.
   First underrun counter snapshots are the original ring's cumulative values. */
typedef struct SesDriverDiagnostics {
    uint32_t version,size;
    uint64_t capture_calls,total_requested_frames;
    uint32_t max_capture_frames,max_pull_chunk_frames;
    uint32_t last_capture_queued_before,last_capture_queued_after,last_capture_frames,reserved0;
    uint64_t last_capture_tick_hns;
    uint64_t last_successful_write_tick_hns,last_successful_write_gap_hns,max_successful_write_gap_hns;
    uint32_t first_underrun_present,first_underrun_queued_before,first_underrun_chunk_frames;
    /* Remaining original-call frames at chunk entry, INCLUDING this chunk. */
    uint32_t first_underrun_remaining_frames,first_underrun_capture_frames;
    uint32_t first_underrun_old_count,first_underrun_new_count,reserved1;
    uint64_t first_underrun_tick_hns,first_underrun_since_successful_write_hns;
    uint64_t first_underrun_successful_write_tick_hns,first_underrun_received_frames;
    uint64_t first_underrun_silence_before,first_underrun_silence_after;
} SesDriverDiagnostics;
#pragma pack(pop)
#ifdef __cplusplus
static_assert(sizeof(SesDriverHello)==24);
static_assert(sizeof(SesDriverPacket)==1944);
static_assert(sizeof(SesDriverStatus)==48);
static_assert(sizeof(SesDriverDiagnostics)==160);
#endif
