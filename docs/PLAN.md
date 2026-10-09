# Current approved scope — general microphone and voice utility

Veylo is a general-purpose Windows microphone and voice-processing application
for recording, streaming, meetings, voice communication and games. Discord and
Valorant are examples, not the product definition or mandatory core-quality
acceptance gates. Game mode remains an optional exposed feature with its own
performance checks. Single-microphone and local-processing scope remains.

The user's latest routing decision is VB-CABLE as the default daily route:
physical microphone -> Veylo -> CABLE Input; the receiving application chooses CABLE Output.
Processing starts automatically. Old profiles and calibration remain supported.
The capture-only Veylo Mikrofon driver remains an explicitly selected development
option; signing and kernel-lab work remain separate from normal usage and retain their acceptance
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
