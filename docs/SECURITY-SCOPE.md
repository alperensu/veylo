# Güvenlik kapsamı ve teknik notlar

Bu belge teknik güven sınırlarını ve önceki sürümlerin güvenlik notlarını saklar.
Güvenlik açığı bildirimleri için [SECURITY.md](../SECURITY.md) kullanın; burada
listelenen kontroller bütün sistemin güvenli olduğuna ilişkin garanti değildir.

## Güncel doğrulama sınırı — 0.7.5-dev

Uygulama/native ABI **5**, sürücü **0.5.1.0**, sürücü protokolü **1**.
Günlük Windows çıkışı VB-CABLE'dır; normal Setup kendi kernel sürücümüzü içermez.
Taşınabilir uygulama ve normal Setup kod imzalı değildir. Sürücü için ayrı
laboratuvar test imzalı paket vardır; bu Microsoft üretim imzası değildir ve
normal kurulum yardımcısı tarafından kabul edilmez.

İzole Windows 11 laboratuvarında 104 IOCTL kontrolü ve 20 gerçek WASAPI capture
kontrolü normal koşulda ve Driver Verifier açıkken geçti; PnP yaşam döngüsü
kontrolleri de geçti. HVCI, uzun süreli dayanıklılık, Microsoft üretim imzası ve
alıcı uygulama kabulü tamamlanmadı. Aşağıdaki sürüm notlarında geçen eski
doğrulama durumları kendi dönemini anlatır. Güncel kanıt ve kalan kabul kapıları:
[VALIDATION.md](VALIDATION.md), [DRIVER-LAB.md](DRIVER-LAB.md) ve
[ACCEPTANCE.md](ACCEPTANCE.md).

## VB-CABLE routing (0.5.2)

Routing uses already installed WASAPI devices; no driver installation, UAC, boot
policy change, downloads or arbitrary DLL/plugin loading is introduced. Persisted
output mode is limited to cable/driver/local. Output IDs must match enumerated
CABLE Input render devices; physical speakers are excluded even for stale state.
Corrupt saved state recovers with local-only output, preventing unintended
transmission from a default microphone to a newly selected cable.
Cable detection uses the endpoint display name, not publisher authentication; a
same-user/admin process can rename a different endpoint to impersonate that name.
Do not treat the label as a security identity. Known CABLE Output sources are rejected before opening a cable route, preventing
self-feedback even when the destination is currently missing. Unknown/missing
cable sources wait for enumeration before opening transmission, so native
reconnection cannot bypass source validation.
Audio stays in the bounded existing
ring. Missing saved cable is not replaced; shared presets contain no routing IDs.


## Virtual microphone trust boundaries (0.5.0 development)

The daily desktop runs without administrator privileges. The separate installer
requests UAC only for install/update/remove/rollback. It manages the exact Veylo
hardware identity; arbitrary INF paths or driver names are not accepted. Daily
security settings and test-signing policy are never changed.

The private control device allows System/admin and interactive users. A single
file object owns the PCM producer connection; IOCTL lengths, version, format, reserved fields and
sequence are validated before copying into a bounded ring. Ownership is not
application identity: another process running as the same interactive user can
race to claim the connection or supply its own PCM. The app reports busy/access
errors. Protocol checks do not authenticate voice or prevent same-user interference.
The WDM dispatch forwards only non-control requests to PortCls. PCM processing is
integer-only under a bounded spinlock; stale/disconnected/starved audio is zeroed.

Installer files are size-bounded; input file reparse points are rejected. The INF
must match embedded Veylo bytes. Loaded bytes are staged under Program Files before
catalog verification; no path from UI input is executed. SignedCms and online
Windows chain checks require a trusted Microsoft Windows catalog signer. Windows
PnP subsequently enforces catalog membership and kernel signing policy. Four read-only rejection tests cover malformed, unsigned, untrusted Microsoft-name and multiple-signer catalogs; no certificates were imported. Unsigned development CAT/SYS files and the separate lab test-signed package cannot pass this release installer.

Verified: dependency pin hashes, secret scan, user-mode Clang/.NET analysis,
AddressSanitizer and transport misuse tests; EWDK DriverRecommendedRules analysis,
InfVerif and Inf2Cat. No elevated installation or kernel abuse test ran on this
machine. At that release, Driver Verifier, HVCI, sleep/unplug/crash/update/rollback and live game
compatibility remained required in an isolated lab with a correctly signed package.
See the current validation boundary above for subsequent isolated-lab results.
A compile/SAST pass is not proof of kernel safety or Vanguard compatibility.

Offline local desktop, no cloud/accounts/HTTP endpoints. Boundaries:
untrusted presets, corrupt state, DLL search paths, malformed audio/parameters,
bounded samples. Shared profiles omit device IDs/voice. RAM voice is not saved
without export; OS paging/crash dumps remain operating-system behavior.

scripts/security.ps1: dependency hashes, Gitleaks, .NET vulnerability metadata,
Clang SAST and managed analyzers. Native AddressSanitizer via build/test -Sanitize.
Regressions cover malformed/duplicate/oversize profiles, mute/limiter/silence,
alignment/transitions and ABI. DAST/auth/IDOR do not apply: no web backend.

Personal calibration accepts only bounded 20s mono arrays and rejects nonfinite
or clipped input. Recommendations validate before mutation; applying to a
different endpoint fails. Profile/device limits are checked before creating
state. Optional per-device settings are validated on load, within the existing
1MiB local state/64KiB shared-profile limits. Offline previews use a separate
engine and the limiter. Regression tests cover rejection, endpoint isolation,
apply/undo, local persistence and voice/device-free sharing. Speech detection
and tone estimation quality are separate listening-validation concerns.

Portable package is unsigned. The source repository is public:
[alperensu/veylo](https://github.com/alperensu/veylo).
Follow the current [security reporting policy](../SECURITY.md). Do not post
secrets, personal audio or local state in public Issues.
Sensitivity config uses validated boolean flags and finite bounded thresholds;
ABI4 size/version checks reject mixed UI/DLL releases. Tests cover default-off
legacy profiles, mode persistence, below-threshold output, bypass/mute/limiter
and overloaded input. AddressSanitizer covers the new callback envelope.
Report reproduction/affected version without publishing recordings/local state.

## Game mode and UI preferences (0.5.1)

The detector reads process names and foreground-window geometry every 5 seconds
on a worker; it does not open game memory, inject code, read command lines, change
priority or persist process inventories. Detection stops when automatic mode is
turned off. One outstanding poll is allowed; exit stops the timer/unsubscribes
Windows settings events. Known-name/fullscreen matching is heuristic, not proof
that a foreground application is a game. The UI discloses that limitation.

Custom process names are bounded to 20×96 characters, validated at entry and local
state load/save, and never executed or interpreted as paths. Duplicate .exe/non-
.exe names and command/path characters are rejected. Local preferences remain
outside shareable profiles. Regression tests cover these boundaries, defaults,
persistence and deterministic 15s recovery hold. No new dependency or driver API.

## 0.6.0 scoped controls
Local shortcut settings validate enum, letters and active conflicts. New bindings
are transactional; no Windows/Discord defaults or driver installation changes.
Only configured chord states are sampled; no key logs/history/hook/injection.
PTT starts closed and bypass cannot unmute. Native gate values and all expander
parameters are checked before assignment; no RT allocation/lock was introduced.
These checks do not demonstrate Vanguard compatibility or complete Windows
lock/sleep/physical-key behavior. Already queued speech may take a few milliseconds
to drain after key release.
