# Architecture

Veylo is a general Windows microphone-processing utility. Recording, streaming,
meeting, voice-chat and game applications are consumers of its processed capture
endpoint. Named applications in historical checkpoints are compatibility
examples, not a restriction on the product or its core quality acceptance.

## 0.5.2 explicit routing with VB-CABLE as default

Default route: physical microphone -> native DSP -> bounded WASAPI ring ->
CABLE Input render endpoint -> CABLE Output capture endpoint -> receiving application.
Only VB-CABLE render endpoints are offered, never physical speakers. Output mode
(cable/driver/local) persists separately from the saved cable ID; older states
default to cable without changing presets or calibration. A saved missing cable
is not substituted. Missing first-use cable processes locally and refreshes for
the exact saved endpoint (or first cable when no ID was saved).

Explicit driver route: native DSP -> bounded producer queue -> private PCM ->
Veylo Mikrofon capture endpoint. This option does not create a render endpoint;
missing/incompatible driver leaves DSP running locally. Local mode never sends
continuous audio. OS/application defaults are not changed. The unsigned Veylo driver
is not installed or used by the default VB-CABLE route.

Native ABI4 separates output kind and driver status/counters from DSP settings.
UI/DLL size and ABI checks fail closed. Shared JSON remains schema1 and previous
profiles/device calibration remain compatible; saved cable IDs are honored only when matched to an eligible VB-CABLE endpoint.
The device marker rejects Veylo as an input. First-use selection prefers the Windows
physical default; loss of a saved input waits for that exact endpoint.
WPF serializes start/stop/dispose through a lifecycle semaphore. Loaded starts
processing, including hidden startup. Close hides; tray Exit disposes the engine.
Calibration and comparison capture do not stop daily processing.

The callback pushes 480 floats into four preallocated SPSC blocks. Driver IO is
confined to a worker; unsent blocks older than50ms are discarded. Protocol1 uses
48kHz mono PCM32; version/size/format/owner/sequence mismatch is rejected. Kernel
capture converts to PCM16/PCM32 with integer arithmetic and bounded clock-drift
correction; its4096-frame ring discards on starvation, disconnect or100ms producer
timeout. No RNNoise, EQ, floating-point DSP, file logging or voice persistence in
the kernel. These limits are not an end-to-end latency measurement.

SYSVAD is pinned and reproducibly adapted: one MicIn host capture, no render,
loopback, tone generator, sideband or audio modules. Original sources and license
are retained. EWDK/INF/SAST builds pass; production signing and isolated Windows
lifecycle/HVCI/Verifier and capture-application compatibility remain external driver release gates.

Native DLL owns WASAPI capture and user-mode DSP; no managed audio callback.
UI polls atomic meters at10Hz, stops rendering while hidden. Owner serializes
lifecycle/sample calls; validated atomic settings/metrics coexist with live audio.
Audio callbacks use preallocated memory without files or blocking locks.

C ABI4 includes the driver fields above and automatic-noise/sensitivity flags and applied mix/ambient/
sensitivity threshold/gain metrics. ABI2 introduced automatic noise strength.
UI and native DLL are shipped together; size/version mismatches fail closed.
Shared JSON schema remains 1: older presets default to manual mode.
Automatic strength uses the existing RNNoise VAD and input RMS every 10 ms.
VAD >= .35 excludes speech and a 300 ms hangover from ambient learning; VAD
<= .15 permits updates. Ambient estimate rises with a roughly 1 s time constant
and falls over roughly 5 s, bounded -100 to -20 dBFS. Mix maps to .35–.95;
automatic transitions move by at most one full-scale mix per second. Manual
mix is retained separately. No gate or extra neural inference is introduced.
Detection errors can still affect speech; real listening remains necessary.

Optional input sensitivity is a separate transmission envelope after compressor,
before dry bypass and limiter. Manual threshold -90..-10dBFS; auto uses the
existing ambient estimate+10dB, bounded -75..-20, slew <=2dB/s. Auto RNNoise
VAD>=.2 with input>ambient+3dB can protect soft speech below the threshold.
6dB closing hysteresis,300ms hold,2ms attack/120ms exponential release avoid hard
cuts; below1e-5 gain snaps to zero. Existing20ms processing delay supplies onset
lookahead without extra audio buffering. No allocations, extra inference or
managed callbacks. Disabled passes continuously; bypass skips the envelope,
mute/limiter remain active. Shared schema1 stays compatible: legacy/default
profiles disable sensitivity, auto/manual values saved independently. Personal
calibration now proposes automatic sensitivity too; detection is not perfect.

WPF category navigation changes visibility of existing controls, preserving
the engine and unsaved settings. Small windows use scrollable icon navigation
with localized tooltips and accessible names. Transport controls stay visible.

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

20s raw/processed arrays preallocated; basic calibration15s. A/B reprocesses raw
in a separate stopped engine, aligns960, attenuates to quieter RMS. No cloud
or HTTP service. Only explicit WAV export writes voice files; settings are
per-user atomic JSON. Native DLL loads from absolute application directory with
dependency search limited to there/System32. No external plugins/model loaders.

Personal calibration (0.3.0) captures exactly20s: ambient5s, normal7s, soft4s,
louder4s. Offline analysis runs on a worker with a separate native engine,
never in a live audio callback. 20ms DC-removed RMS percentiles estimate level
and dynamics; the existing RNNoise model checks speech in every prompted phase.
400ms start/200ms end margins exclude reactions and phase transitions. Invalid
length/nonfinite/clipped samples, insufficient speech, contaminated ambient and
poor separation are rejected. VAD is fallible; this is not speaker recognition.
Five first-order analysis bands subtract ambient power and recommend bounded
tone corrections (-2 to +1dB), not a reconstructed or universally ideal voice.
The target stays -20dBFS, gain within +/-12dB, limiter -1dBFS; output gain0.
The UI shows before/after, loudness-matched preview, explicit apply and one-use
session undo. Capture/analysis do not change settings. A validated user profile
and optional TunedSettings are saved per endpoint with backward-compatible
local JSON. Shared profile schema1 remains device/voice-free. Preset and basic
ambient calibration changes retain TunedSettings. Microphone switches discard
pending suggestions/undo; routing and Windows microphone level are preserved.

## 0.6.0 ABI5 and transmission controls
Native ABI5 appends sensitivity mode, attack/hold/release/hysteresis, ratio and
maximum reduction to DSP configuration (192 bytes); metrics and driver protocol1
are unchanged. Legacy schema1 profiles obtain defaults from property initializers.
Gate defaults retain 2/300/120 ms, 6 dB hysteresis. Expander is optional, unity
above threshold, a bounded downward curve with 6 dB soft knee below threshold.
Detector/hold use 10 ms blocks; attack/release are sample-rate envelopes.
Talk gate is separate packed atomic mode/held state, never serialized in DSP
presets, read at final output including bypass. Manual mute dominates.
A 20 ms background timer samples only configured chord high-bit state and
updates native atomic state without UI dispatch/config writes. Disposal serializes
with polling before releasing engine. Hotkeys reserve added chords before removing
old ones; conflict rolls back new reservations leaving existing actions intact.
Preset identifiers are fixed factory IDs, unaffected by user presets.
Hold timer is disabled in open mode. No low-level keyboard hooks/key logs.

## 0.6.3 development: packet clocks, causal FIFO and transient gain history

Current ABI5 keeps config192 and metrics136. The optional version1/size96
stream-diagnostics extension reports callback counts, maximum frame sizes/gaps,
FIFO fill, waiting and true starvation state. It contains no PCM or identifiers.
Older ABI5 libraries return null through the managed optional extension.

WASAPI uses the shared bounded AudioFifo implementation tested with complete
480-sample producer packets, rather than fractional continuous-production math.
A playback-owned PI servo learns the drift, with ratio authority±1000ppm and
unchanged nominal20ms FIFO target. Causal previous/current interpolation adds
one sample of alignment (1/48000s). Pending source advances consume only
published samples; history is copied before cells are released. Starvation
refreshes the producer cursor before reporting a genuine missing sample, clears
phase/history and emits a zero remainder. Initial priming accounts for negotiated
callback size; unusually large periods may exceed the latency target. No callback
heap allocation, mutex, syscall logging or kernel change was introduced.

RNNoise retains the full v0.2 model and includes the official bb18d2f transient
gain-history energy compensation backport. The changed vendor source checksum
and BSD notice are retained. Model/state/frame delay stays unchanged. This is
a limited gain-decay fix, not speech recognition or guaranteed impact removal.
The synthetic RN-only A/B did not remove the large desk-impact peak.

GameDetector uses Unicode process-only ToolHelp snapshots with owned SafeHandle
lifetime; foreground/fullscreen/custom-name policy is unchanged. The developer
live sampler reads fixed Win32 own-process memory/time structures and includes
managed heap/allocation counters without collecting heaps, voice or identifiers.
No forced collection or OS working-set trimming is used.

## 0.6.4 development: speech-aware automatic soft expansion

Only automatic sensitivity + soft expander + enabled RNNoise uses the speech
probability to open/renew hold. Level alone cannot open or renew this mode.
Outside speech hold, low confidence adds a smooth bounded reduction floor
(30 dB at VAD0 with ratio2, limited by user maximum); unity ratio stays unity.
Manual sensitivity, gate mode, disabled noise reduction and bypass keep their
existing behavior. No extra buffering/inference/allocation is added. High-VAD
impacts can still pass; this is not a desk-impact classifier or a privacy gate.
Quiet unvoiced onsets below the speech threshold can be attenuated; existing
level lookahead no longer opens this mode before speech detection. The
configured sample attack and speech hold smooth transitions, not a guarantee
that every cold onset is preserved. Listening acceptance remains required.

## 0.6.5 development: callback-aware FIFO reserve

WASAPI now uses readBuffered: preTarget = callbackFrames + bufferFrames -
240 (half the capture packet), with saturating addition. For the default
20ms setting this leaves a 720-frame/15ms nominal post-render target; packet
phase and scheduling still affect actual latency. Servo error is normalized
by the 480-frame capture packet, not callback-dependent preTarget; integral
time scales by rendered frames. Raw read keeps its prior normalization for
legacy/oracle checks. No extra allocation, locks, replay or starve masking.
10ms buffers are a best-effort low-reserve choice. Measured end-to-end
40ms acceptance and a complete clean live hour remain unproven.
The buffer estimate now uses pre-render startingFill, not remainingFill
after consuming this callback: the latter omitted the delivered callback
from its queue estimate. This reports RN20ms + queued source at render start,
excluding hardware/capture scheduling and external application buffers.
Post-render reserve is a stability budget, not the age of delivered audio.

## 0.6.6 development: game-policy allocation

Process-name validation uses a character loop and custom-name matching uses
an indexed, ordinal-ignore-case comparison over spans. Matching `.exe` suffixes
does not create normalized custom strings or captured LINQ predicates per
observation. Known games, fullscreen exclusions, custom override precedence,
5-second monitoring and 15-second hold remain unchanged. No new detector cache,
process access, audio work or GC configuration is introduced. This reduces
temporary policy allocations, not proof of lower retained working set.

## 0.6.7 development: filtered metadata polling and period request

PROCESSENTRY32W uses an inline ushort[260] UTF-16 buffer, not a marshalled
string. Layout size/name offset are checked at startup (x64:568/44).
Normal polling returns only the first matching observation, using the same
span validation and precedence as GameModePolicy.Update. Compatibility Read()
still returns the full metadata list. SafeHandle owns the Toolhelp snapshot;
no process is opened and no executable path is read. Custom names are copied
on the UI thread; if their list is replaced during the scan, it is rescanned.
Disable/quit still invalidates the result. No process cache or GC policy is added.

The managed device request is now5ms; bufferMs remains20. RNNoise still receives
480-frame blocks. WASAPI negotiates the supported hardware period; the requested
period is not a measured latency or a promise that every endpoint supports5ms.
On this host, read-only IAudioClient3 queries show the physical USB input fixed
at480 frames, and CABLE render permitting128..480 frames at48kHz. The actual
5ms probe negotiated240 render frames and480 capture frames with240-frame
external callbacks. Native conversion flags, DSP, FIFO and ABI5 are unchanged.
The sampled RN20ms+FIFO estimate excludes hardware and consumer buffers.

## 0.6.8 development: explicit low-overhead diagnostics and startup refresh

The developer-only --validate-low-overhead flag requires --validate-live;
otherwise initialization fails before user state or audio is opened. It retains
the isolated muted path,2-second RAM-only sample lifecycle, game/session timers,
5ms request and20ms reserve. Polling is1Hz vs10Hz; metadata progress is30s vs10s.
The timeline contains only counters/GC sizes and resets for each run; duration
remains bounded1..3600 seconds. No forced GC, heap limit, heap objects, voice
recording, working-set trimming or audio-thread work is added. Low-rate snapshots
can miss brief state/DSP changes; cumulative native buffer counters remain used.
Working-set acceptance uses the OS lifetime peak, including startup, so sparse
sampling cannot hide a peak. The validation process omits normal tray/hotkeys;
normalProductBaseline is explicitly false. GC committed bytes reflect the last
collection and can be zero before the first collection; they are not live heap.

Normal startup refreshes only an existing REG_SZ SES Run entry with the exact
quoted local SES.exe --minimized (Veylo.exe is also accepted after rebranding) command. Pure policy rejects malformed commands,
UNC/device/relative paths, ADS and extra arguments. Known file versions prevent
downgrades; equal-version relocation is allowed. The entry is read again before
writing to avoid replacing an intervening edit. No missing preference/key is
created; validation never refreshes registration. --repair-startup performs only
this repair and exits without opening audio, changing state or stopping another
instance. Combining repair with validation is rejected.
