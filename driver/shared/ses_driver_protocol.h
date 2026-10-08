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
#pragma pack(pop)
#ifdef __cplusplus
static_assert(sizeof(SesDriverHello)==24);
static_assert(sizeof(SesDriverPacket)==1944);
static_assert(sizeof(SesDriverStatus)==48);
#endif
