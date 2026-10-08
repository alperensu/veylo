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
#define SES_ABI_VERSION 5u
#define SES_RATE 48000u
#define SES_BLOCK 480u
#define SES_MAX_SAMPLE_FRAMES (SES_RATE * 20u)
typedef struct SesEngine SesEngine;
typedef struct SesBand { int32_t type; float frequency, gain_db, q; } SesBand;
/* Band type: 0=peak, 1=low shelf, 2=high shelf. Flags are uint32, not C++ bool. */
typedef struct SesDspConfig {
    uint32_t version, size, noise_enabled, agc_enabled, deesser_enabled, muted, bypass, noise_auto_enabled, sensitivity_enabled, sensitivity_auto_enabled;
    float highpass_hz, noise_mix, target_db, min_gain_db, max_gain_db;
    float compressor_threshold_db, compressor_ratio, attack_ms, release_ms, knee_db;
    float deesser_max_db, output_db, noise_floor_db, speech_threshold, sensitivity_threshold_db;
    SesBand bands[4];
    uint32_t sensitivity_mode; /* 0=gate, 1=soft downward expander. */
    float sensitivity_attack_ms, sensitivity_hold_ms, sensitivity_release_ms, sensitivity_hysteresis_db;
    float sensitivity_ratio, sensitivity_max_reduction_db;
} SesDspConfig;
typedef struct SesDevice { char id[512], name[512]; uint32_t kind, is_default, is_ses_virtual; } SesDevice;
enum SesOutputKind { SES_OUTPUT_LOCAL=0, SES_OUTPUT_DRIVER=1, SES_OUTPUT_WASAPI=2 };
typedef struct SesDeviceConfig {
    uint32_t version, size;
    char input_id[512], output_id[512]; /* Empty output = capture-only. Empty input is invalid. */
    uint32_t period_ms, buffer_ms, output_kind;
} SesDeviceConfig;
typedef struct SesMetrics {
    float input_db, output_db, gain_db, compression_db, speech_probability;
    float processing_ms, estimated_buffer_ms, drift_ppm, noise_mix, noise_floor_db, sensitivity_threshold_db, sensitivity_gain;
    uint64_t processed_frames, clipped_samples;
    uint32_t running, connected, underruns, overruns, sample_frames, error_code;
    uint32_t output_kind, driver_status, driver_protocol, driver_error, driver_queued_frames, driver_underruns, driver_overruns;
    int32_t driver_drift_ppm;
    uint64_t driver_sent_frames, driver_silence_frames;
} SesMetrics;
/* Optional diagnostics extension; ABI5 settings/metrics layouts remain unchanged.
   No audio samples, device identifiers or process data are exposed. */
#define SES_STREAM_DIAGNOSTICS_VERSION 1u
typedef struct SesStreamDiagnostics {
    uint32_t version,size;
    uint64_t capture_callbacks,playback_callbacks,capture_max_gap_us,playback_max_gap_us,capture_max_duration_us;
    uint32_t capture_max_frames,playback_max_frames,fifo_min_starting_frames,fifo_max_starting_frames;
    uint32_t waiting_callbacks,last_underflow_available_frames,last_underflow_remaining_frames,refreshed_writes;
    uint32_t capture_period_frames,playback_period_frames,capture_device_rate,playback_device_rate;
} SesStreamDiagnostics;
SES_API uint32_t ses_abi_version(void);
SES_API uint32_t ses_config_size(void);
SES_API uint32_t ses_metrics_size(void);
SES_API void ses_default_config(SesDspConfig* config);
SES_API int ses_validate_config(const SesDspConfig* config);
SES_API int ses_list_devices(SesDevice* devices, uint32_t capacity, uint32_t* count);
SES_API SesEngine* ses_create(void);
SES_API void ses_destroy(SesEngine* engine);
SES_API int ses_update(SesEngine* engine, const SesDspConfig* config);
/* Live, nonpersistent gate: 0=open, 1=push-to-talk, 2=hold-to-mute; held is 0/1.
   Safe alongside update/process/live audio; manual config mute always wins. */
SES_API int ses_set_talk_gate(SesEngine* engine, uint32_t mode, uint32_t held);
SES_API int ses_start(SesEngine* engine, const SesDeviceConfig* config);
SES_API void ses_stop(SesEngine* engine);
SES_API int ses_read_metrics(SesEngine* engine, SesMetrics* metrics);
/* Exact extension version and struct size are checked before writing output. */
SES_API int ses_read_stream_diagnostics(SesEngine* engine,uint32_t version,uint32_t size,SesStreamDiagnostics* diagnostics);
/* Control/lifetime/sample calls must be serialized by the owner; update, talk gate
   and metrics may run alongside live audio. Offline processing only while stopped, frames must
   be divisible by SES_BLOCK; buffers may alias. */
SES_API int ses_process(SesEngine* engine, const float* input, float* output, uint32_t frames);
SES_API int ses_begin_sample(SesEngine* engine, uint32_t seconds);
SES_API void ses_end_sample(SesEngine* engine);
/* Copies only committed memory. which=0 raw, 1 processed. Recording stays local. */
SES_API uint32_t ses_copy_sample(SesEngine* engine, uint32_t which, float* output, uint32_t capacity);
#ifdef __cplusplus
}
#endif
