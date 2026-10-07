#pragma once
#include <stdint.h>
#ifdef _WIN32
#ifdef SES_BUILD
#define SES_API __declspec(dllexport)
#else
#define SES_API __declspec(dllimport)
#endif
#else
#define SES_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
#define SES_ABI_VERSION 1u
#define SES_RATE 48000u
#define SES_BLOCK 480u
#define SES_MAX_SAMPLE_FRAMES (SES_RATE * 20u)
typedef struct SesEngine SesEngine;
typedef struct SesBand { int32_t type; float frequency, gain_db, q; } SesBand;
/* Band type: 0=peak, 1=low shelf, 2=high shelf. Flags are uint32, not C++ bool. */
typedef struct SesDspConfig {
    uint32_t version, size, noise_enabled, agc_enabled, deesser_enabled, muted, bypass;
    float highpass_hz, noise_mix, target_db, min_gain_db, max_gain_db;
    float compressor_threshold_db, compressor_ratio, attack_ms, release_ms, knee_db;
    float deesser_max_db, output_db, noise_floor_db, speech_threshold;
    SesBand bands[4];
} SesDspConfig;
typedef struct SesDevice { char id[512], name[512]; uint32_t kind, is_default; } SesDevice;
typedef struct SesDeviceConfig {
    uint32_t version, size;
    char input_id[512], output_id[512]; /* Empty output = capture-only. Empty input is invalid. */
    uint32_t period_ms, buffer_ms;
} SesDeviceConfig;
typedef struct SesMetrics {
    float input_db, output_db, gain_db, compression_db, speech_probability;
    float processing_ms, estimated_buffer_ms, drift_ppm;
    uint64_t processed_frames, clipped_samples;
    uint32_t running, connected, underruns, overruns, sample_frames, error_code;
} SesMetrics;
SES_API uint32_t ses_abi_version(void);
SES_API uint32_t ses_config_size(void);
SES_API uint32_t ses_metrics_size(void);
SES_API void ses_default_config(SesDspConfig* config);
SES_API int ses_validate_config(const SesDspConfig* config);
SES_API int ses_list_devices(SesDevice* devices, uint32_t capacity, uint32_t* count);
SES_API SesEngine* ses_create(void);
SES_API void ses_destroy(SesEngine* engine);
SES_API int ses_update(SesEngine* engine, const SesDspConfig* config);
SES_API int ses_start(SesEngine* engine, const SesDeviceConfig* config);
SES_API void ses_stop(SesEngine* engine);
SES_API int ses_read_metrics(SesEngine* engine, SesMetrics* metrics);
/* Control/lifetime/sample calls must be serialized by the owner; update and metrics
   may run alongside live audio. Offline processing only while stopped, frames must
   be divisible by SES_BLOCK; buffers may alias. */
SES_API int ses_process(SesEngine* engine, const float* input, float* output, uint32_t frames);
SES_API int ses_begin_sample(SesEngine* engine, uint32_t seconds);
SES_API void ses_end_sample(SesEngine* engine);
/* Copies only committed memory. which=0 raw, 1 processed. Recording stays local. */
SES_API uint32_t ses_copy_sample(SesEngine* engine, uint32_t which, float* output, uint32_t capacity);
#ifdef __cplusplus
}
#endif
