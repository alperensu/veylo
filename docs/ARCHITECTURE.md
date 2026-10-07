# Architecture

Native DLL owns WASAPI capture/render and all DSP; no managed audio callback.
UI polls atomic meters at10Hz, stops rendering while hidden. Owner serializes
lifecycle/sample calls; validated atomic settings/metrics coexist with live audio.
Audio callbacks use preallocated memory without files or blocking locks.

48kHz mono float /480samples. miniaudio converts hardware rate/channel/format.
Preallocated SPSC FIFO compensates independent clocks using ±1000ppm adaptive
interpolation. Supervisor retries exact endpoint IDs every250ms after loss,
silences disconnected output; capture heartbeat expires within2seconds.

HPF → RNNoise → slow speech-gated AGC →4band EQ → de-esser → compressor →limiter.
RNNoise v0.2 has **960samples/20ms** delay, verified by non-periodic chirp;
dry/bypass and A/B match this delay. Inference stays warm when disabled. Mixes
and output gain ramp per sample; filter coefficients ramp over each frame.
AGC targets−20dBFS processed speech RMS, bounded±12dB, freezes outside speech.
Compressor attack10/release120ms/soft knee6dB/no makeup; limiter−1dBFS in all
modes. NaN/infinity sanitized. Immediate mute is the privacy boundary.

20s raw/processed arrays preallocated; calibration15s. A/B reprocesses raw
in a separate stopped engine, aligns960, attenuates to quieter RMS. No cloud
or HTTP service. Only explicit WAV export writes voice files; settings are
per-user atomic JSON. Native DLL loads from absolute application directory with
dependency search limited to there/System32. No external plugins/model loaders.
