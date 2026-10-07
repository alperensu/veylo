# Security scope

Offline local app, no admin privileges/cloud/accounts/HTTP endpoints. Boundaries:
untrusted presets, corrupt state, DLL search paths, malformed audio/parameters,
bounded samples. Shared profiles omit device IDs/voice. RAM voice is not saved
without export; OS paging/crash dumps remain operating-system behavior.

scripts/security.ps1: dependency hashes, Gitleaks, .NET vulnerability metadata,
Clang SAST and managed analyzers. Native AddressSanitizer via build/test -Sanitize.
Regressions cover malformed/duplicate/oversize profiles, mute/limiter/silence,
alignment/transitions and ABI. DAST/auth/IDOR do not apply: no web backend.

Portable package is unsigned. No public repo or reporting inbox is configured.
Report reproduction/affected version without publishing recordings/local state.
