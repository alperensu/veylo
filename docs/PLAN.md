# SES v1 — approved implementation brief

Windows 10/11 x64 microphone processing, offline and open-source-ready (MIT).
Native C++20 / miniaudio 0.11.25 / RNNoise v0.2 audio DLL; .NET 10 WPF shell.
Physical mic -> SES -> CABLE Input; Discord / Valorant choose CABLE Output.
VB-CABLE is separately installed from its official site, never bundled.

## Deliverables
1. Native audio engine, versioned C ABI, preallocated realtime path, bounded
   clock-drift compensation, safe disconnect / same-device reconnect.
2. HPF -> RNNoise -> speech-gated slow AGC -> four-band EQ -> de-esser ->
   soft-knee compressor -> safety limiter. Mute and limiter survive bypass.
   48 kHz mono float / 480-sample blocks, gain +/-12 dB, RMS target -20 dBFS,
   compressor attack 10 ms / release 120 ms / knee 6 dB, ceiling -1 dBFS.
3. Natural (80 Hz, flat, 2:1/-18), Clear (100 Hz, +2 dB/3 kHz, 2.5:1/-20),
   Warm (70 Hz, +2 dB low shelf/180 Hz, 2:1/-18), Broadcast (80 Hz,
   +2 dB low shelf/150 Hz and +2 dB/3 kHz, 3:1/-22, de-esser max 3 dB).
4. Device-local calibration (5 s ambient + 10 s speech), editable presets,
   bounded versioned JSON import/export without device IDs or voice samples.
5. TR/EN shell: routing, meters, simple/advanced controls, level-matched A/B
   on <=20 s memory-only samples; opt-in WAV export; tray; configurable
   Ctrl+Alt+M / Ctrl+Alt+B; opt-in startup; keyboard/accessibility/DPI support.
6. Reproducible self-contained x64 ZIP, source, tests, licenses, setup guide,
   security checks, honest device and performance validation report.

## Acceptance
Test speech/noise/level steps/clipping; silence cannot grow AGC; finite bounded
output; click-free changes; sample-rate/channel adaptation; disconnect/reconnect;
one-hour clock drift; malformed profiles; secure native-library loading.
Build, native + managed tests, SAST/secrets/dependency checks and actual UI QA.
Targets on Ryzen 5 7600: CPU <=3%, hidden UI working set <=150 MB, added
latency <=40 ms. Never label target estimates as measured results. Actual
Discord+Valorant, Turkish speech and second-PC tests must be identified as
verified or pending; microphone fault cause is unknown.
