# Current approved scope — general microphone and voice utility

Veylo is a general-purpose Windows microphone and voice-processing application
for recording, streaming, meetings, voice communication and games. Discord and
Valorant are examples, not the product definition or mandatory core-quality
acceptance gates. Game mode remains an optional exposed feature with its own
performance checks. This clarification supersedes the app-specific emphasis
in the historical brief below; single-microphone/local processing scope remains.

The user's latest routing decision is VB-CABLE as the default daily route:
physical microphone -> Veylo -> CABLE Input; the receiving application chooses CABLE Output.
Processing starts automatically. Old profiles and calibration remain supported.
The capture-only Veylo Mikrofon driver remains an explicitly selected development
option; signing and kernel-lab work are deferred, not removed from its acceptance
requirements. Driver absence does not prevent VB-CABLE routing.
See INSTALL.md for current use and VALIDATION.md for evidence and missing checks.
The goal is to make every exposed feature work reliably. On 2026-10-08 the user
reported that noise is now cleaned and there is no problem in their current setup.
Record this as user-confirmed noise-cleaning acceptance, without inferring a
particular build, preset or controlled speech/impact test. Wider microphone and
application compatibility, hidden-runtime resources, physical latency/reconnect
and accessibility acceptance remain incomplete. Specific application checks,
including screen-sharing behavior, belong to compatibility coverage.
Builds and synthetic tests alone do not establish daily-use readiness.

## Historical v1 brief

# Veylo v1 — approved implementation brief

Windows 10/11 x64 microphone processing, offline and open-source-ready (MIT).
Native C++20 / miniaudio 0.11.25 / RNNoise v0.2 audio DLL; .NET 10 WPF shell.
Physical mic -> Veylo -> CABLE Input; Discord / Valorant choose CABLE Output.
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
