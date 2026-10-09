# Driver 0.5.2 additive kernel diagnostics — 2026-10-09

Passed: pinned EWDK build, recommended WDK analysis, InfVerif and Inf2Cat with
no warnings/errors. Seven Release and seven ASan groups passed; the final
capture change passed its focused Release/ASan fixtures again (75 checks).
Safe PowerShell tests passed 698 checks, including 362 pure capture-report
fixtures. Secret scanning found no leaks. Both independent read-only Sol
reviews passed after fixing stale automatic-query acknowledgement and a
terminal-query underrun that could otherwise escape the native acceptance gate.

The additive owner-only, fixed 160-byte DIAGNOSTICS request preserves audio
protocol 1 and ABI 5. It records kernel WRITE arrival gaps and the first steady
underrun's capture context using interrupt-time 100 ns units, not QPC or audio
latency. Capture sizes describe individual SesBridgeCapture calls, including
their bounded chunks; they are not complete position-update/DMA-wrap batches.
Normal application operation does not issue the extra diagnostic request.
Instrumented lab runs query on the first underrun and each source session end,
so their timing may differ from ordinary acceptance. All three terminal records
must be valid and underrun-free. A failed terminal query retains an earlier
valid first-event snapshot but never passes acceptance.

Findings: after the mailbox correction, another real product-bridge request
failed at 6,558 ms (36 checks, nine failures), with one steady underrun, no
overruns/drops, upstream lateness 2 ms and maximum completed WRITE gap
15,945 us. The last healthy STATUS publication had 539 queued frames; about
11.634 ms later the first failing publication reported zero queued frames.
The publication ages were 24 and 26 us. This is consistent with ordinary
elapsed consumption; it does not prove a large kernel pull or the reason the
worker's WRITE arrived late. The mailbox fix did not resolve this failure.
Evidence: product-mailbox-7s-findings-serial.log and the preserved
product-mailbox-7s-findings-20261009 snapshot. The VM processes were later
absent and its disk unlocked; normal shutdown and the reason for that exit
were not established for this run.

Test-only signing verified SYS/CAT cryptography and catalog membership, fixed
ZIP contents and deletion of transient private key material. No host trust
store or security policy changed. These are development checks, not Microsoft
production signing, active HVCI, an actual hour, physical microphone latency,
or separate receiving-application acceptance. VB-CABLE remains the daily route.

Passed: driver 0.5.2 installed in the existing isolated BIOS Windows guest
(DevCon exit 0). With active sole-target Code Integrity Verifier 0x021209bb,
the first instrumented actual-product run completed 60,036 ms and all 37
checks (process exit 0). All three valid kernel records had no first steady
underrun; maximum individual capture calls were 176/166/173 frames. The
production bridge had zero steady underruns, overruns and queue drops,
minimum observed queue 485 frames, maximum completed WRITE gap 13,365 us
and upstream lateness 2 ms. This is synthetic input through the actual
DriverBridge/kernel with two shared WASAPI clients in one process. Additional
diagnostic IOCTLs were enabled, so it is separate from normal acceptance.
It does not explain or resolve the previous intermittent failures. Evidence:
kernel-trace-60-pass-serial.log and kerneltrace-install.png; actual capture
tool SHA256 51d4c154c9b36bf7995a28d606426d6b38d4615b1f601ec90a3005e2164dfcd5,
guest runner 4fe14b67ed951770271aa84b467202c852e776d18a28e3dffb8e87290cc824d0,
test-signed SYS d39b8cac03e2145e83eed0c723ef82f38e034c36d09853b2c492b5e8f05fbbce.

Findings in the first extended IOCTL test: all malformed diagnostic sizes
were rejected, but 162 expectations incorrectly required ERROR_BAD_LENGTH
rather than the actual ERROR_INVALID_USER_BUFFER (1784). The exact rejection
expectations were corrected and independently re-reviewed. This initial
269-check run is not counted as Passed. The corrected live rerun passed all
269 checks, zero failures, exit 0. The copied tool was pinned to SHA256
7b2a07a9a7e47db003a9ea6d3afef3db43328aafc7878b98d0442a02ad57833e before
execution; evidence: kerneltrace-ioctl-corrected.png. It checks connected-owner
authorization, other-handle rejection, every short output size, oversized
output and nonzero input, in addition to the previous 104 checks.

Passed: the same driver then completed a normal, non-instrumented actual
ProductBridge run in 60,001 ms, all 36 checks with process exit 0. Steady
underruns/overruns/queue drops were zero; minimum observed queue 479 frames,
maximum completed WRITE gap 13,547 us and upstream lateness 2 ms. Active
sole-target Verifier 0x021209bb remained verified. Both short results and
normal guest shutdown were preserved; both owned process identities were
absent and an exclusive disk open succeeded before snapshot
kernel-trace-short-052-pass-20261009. Evidence:
kernel-trace-normal-60-and-shutdown-serial.log. This does not establish an
actual hour or a root-cause fix for previous intermittent underruns.

# Production bridge acceptance and bounded cancellation — 2026-10-09

Passed: seven native Release and seven AddressSanitizer test groups. The
offline-only driver I/O suite passed 557 checks, including a worker whose
cancellation never completes: stop/join finished within the one-second fixture
guard after the 250 ms cancellation grace. A late fake completion safely wrote
the retained request after the caller/worker was destroyed. One request and two
private handles remain quarantined; 100 rejected restarts allocated no new
storage or handles. This tests injected OS leaves, not a faulty live kernel.
The native module remains loaded for the application process lifetime.

Passed: 57 offline capture analyzer/CLI/flush/counter checks, and 415 safe VM
fixtures including 79 capture-report decisions. Two independent read-only Sol
reviews found and verified fixes for the missing post-snapshot 50 ms deadline
check, exact three-session acceptance, and malformed scalar/array report fields.
Secret scanning found no leaks; Clang analysis had only the two previously
reviewed upstream miniaudio dead initial stores.

The optional ProductBridge mode feeds the real application DriverBridge instead
of replacing it with the strict synthetic producer. Both paths retain the
existing underrun, waveform, timestamp and lifecycle acceptance gates. The
production worker now registers MMCSS Pro Audio/HIGH and bounds cancellation
without freeing pending I/O storage. Kernel source, protocol 1, ABI 5 and the
normal VB-CABLE route are unchanged. Active product-bridge capture is not yet
established at this source checkpoint; the older hour failures below remain.

Findings: the first real ProductBridge 60-second request ended after 23,844 ms
with process exit 1, 36 checks and eight failures. The actual application
worker, upstream and consumers all registered MMCSS; TransferQueue drops=0.
There was one steady underrun, no overruns, maximum completed WRITE gap
25,492 us, upstream lateness 15 ms and minimum observed steady queue 236
frames. Total connected-session silence was 2,571 frames, including priming;
the last steady sample increased silence from 2,212 to 2,571. Two connected
source sessions had run; the third required lifecycle stage was not reached.
The counters and waveform test correctly rejected this result. Atomic STATUS
snapshots may be stale, so they do not establish the exact kernel pull size
or queue occupancy at the start of the write gap. The original output and
normal shutdown were preserved in product-bridge-24s-findings-serial.log,
product-bridge-24s-and-shutdown-serial.log and the owned disk snapshot
product-bridge-24s-findings-20261009. No hour run was started after this failure.

Investigation found a blocking path in the lab producer's measurement
publication: consumer and producer share a mutex while copying the fixed
history. A descheduled consumer can delay upstream callbacks. This is a
test-harness issue, not proof that it caused the recorded underrun; it must
be removed before using the harness to diagnose the production buffer.
Kernel reserve and acceptance thresholds were not relaxed.

Passed: the blocking publication was replaced in both lab producers by a fixed
three-slot single-writer/single-reader mailbox. Sequentially consistent slot
ownership protects plain-field copies; publication never waits for a reader,
and snapshots make at most three attempts before using the reader's cache.
After worker join, the uncontended terminal snapshot reads the actual last
publication. The fixture pins a reader for at least 40 ms while 1,000 writer
updates complete, then checks concurrent copies of the 64-entry history and
the exact terminal publication. Bounds apply to fixture barriers as well.
The worker now timestamps its counter publication; JSON reports independent
publication age, not coherent kernel-counter time or measured audio latency.
Seven Release/ASan groups passed; the final mailbox ordering and diagnostic
checks passed again in focused Release/ASan runs (62 offline checks). Both
independent reviews passed the final change. The kernel reserve comment was
corrected; kernel behavior and all acceptance gates stayed the same. The
first real failure is not explained or repaired merely by these offline passes.
Evidence: product-mailbox-{release,asan,sc-release,sc-asan}.log,
product-mailbox-offline.json and product-mailbox-secrets.log.

Passed: exact source commit dde1d140e43bddc43df534167a7488b156df2cea completed
both GitHub Windows workflows (37980338215 push, 37980344700 pull request),
including managed/native/ASan tests, scanners, application packaging,
installer lifecycle and checksum validation. Tool hash
352dcd02583098a1cf083bfc3b920b31faa0d54821879ba9cc9e4551dc2098a3;
guest runner hash 4f791702aa5d1b0375132500976a8daedb68fe7f5cac4d2243e904ce6b1d2b7f.

Evidence: artifacts/driver-acceptance/{product-native-release.log,
product-native-asan.log,product-capture-final-release.log,
product-capture-final-asan.log,product-bridge-vm-fixtures.log,
product-clang-analysis.log,product-secrets.log}.

# Driver acceptance tools / source checkpoint — 2026-10-09

Passed: six native and six AddressSanitizer groups; 44 offline capture checks,
303 safe VM-control/guest-decision checks, 110 managed checks, offline WPF
persistence/shutdown/smoke, 18 driver-helper checks in a separate output directory,
and existing package/signing checks. The combined headless command stopped on a
pre-existing locked helper DLL; its remaining helper and UI checks passed using
separate output directories. Secret/dependency/static checks and analyzers passed.
No kernel, protocol, ABI or VB-CABLE routing change was made.

Passed: the evaluation VM activated normally during an explicit temporary NAT
window, then cold-booted with networking disabled. LicenseStatus=1 and an active
90-day evaluation were recorded. No rearm, clock manipulation or host activation
change occurred. The older expired-watermark result below is historical.

Passed: active Driver Verifier flags 0x021209bb, including Code Integrity checks,
only SesMicrophone.sys loaded. A completed 60.010-second run passed 30 checks:
PCM16/PCM32 followed by two shared PCM32 clients in one process, each receiving
2,880,000 frames. Maximum producer lateness 3 ms, write completion gap 13,123 us,
IOCTL duration 3,166 us, minimum observed steady queue 384 frames; zero steady
underruns, overruns, timestamp errors or position gaps. Both clients observed
fresh silence on two lifecycle changes and waveform recovery after reconnect.
One underrun during the intentional producer pause is explicitly retained.
These are synthetic signals through the actual guest kernel; two receiving
applications, physical microphone processing and latency are not established.

Passed: after the host reboot, a normal non-elevated guest PowerShell token
reported ELEVATED=False. The checksum-matched capture executable ran as that
interactive user and returned zero: 20 checks, zero findings/unsupported formats,
one verified endpoint and both PCM16/PCM32 formats passed. This verifies the
interactive user's kernel producer/capture access, not the full WPF microphone
route or application compatibility. No device ACL or host permission was changed.

Findings retained: the first requested hour stopped at six seconds with one
steady underrun and 28 ms producer lateness. The test had produced and drained
both consumers in one loop. A dedicated producer with private timer/MMCSS now
separates that work; the subsequent 60-second result above passed. Neither run
completes one-hour acceptance. No reserve increase or weakened gate hid the failure.
The actual application bridge now uses a private high-resolution idle timer;
portable stop/reopen checks passed, but this is not a full-route performance test.

Passed: independent read-only correctness and security reviews and follow-up
fixes for snapshot preservation, scheduler transitions, clock publication races
and startup error evidence. The final registry ACL calls also received a fresh
independent security review after an earlier review attempt hit its usage limit.
Fixed allowlisted registry paths use Get-Acl -Path for Windows PowerShell 5.1 compatibility;
filesystem paths retain -LiteralPath. Actual guest registry corroboration is
recorded separately from active Verifier evidence, and neither proves HVCI.

Findings fixed: the same-version reinstall preflight initially rejected the real
DevCon instance ROOT\\MEDIA\\0000 because it confused an instance ID with the
hardware ID ROOT\\SES_MICROPHONE. No removal occurred on that failed attempt.
The guarded selection now accepts only the two known root instance forms, one
exact hardware target and the exact service. Twenty-three inert identity cases
also passed under Windows PowerShell 5.1; wildcard, foreign and duplicate device
selections remain rejected. Culture-invariant matching preserves Windows ID
case semantics under Turkish culture. Independent follow-up reviews passed.

Passed: the corrected guest runner removed the exact ROOT\\MEDIA\\0000 instance,
confirmed device absence, then reinstalled the verified same-version INF. Both
DevCon commands returned zero and the resulting sole device had error code zero.
This does not establish a different-version upgrade or rollback.

Findings fixed: fresh elevated Windows-2022 CI initially rejected newly created
inert fixture files whose default owner was Administrators. Fixtures now set their
owner to the current user SID, matching the existing metadata fixture pattern;
production ACL guards and guest code are unchanged. Local 149 checks and both
independent reviews passed. Full GitHub CI passed for df9aee2 and fe8590a; the
latest UEFI source checkpoint also passed all 181 safe VM fixtures locally.

Incomplete: the subsequent hour attempt last recorded a heartbeat at 3,491
seconds and did not publish a terminal acceptance result. The daily host later
rebooted (current LastBootUpTime 2026-10-09T11:21:57Z); its former QEMU and
supervisor processes no longer existed. The serial record was preserved before
restarting the guest. This is not a completed hour or a demonstrated driver
bugcheck. A new uninterrupted run is still required.

Findings: guest HVCI configuration persisted the five requested registry values
and both BCD launch settings, with its first baseline preserved. The subsequent
cold boot stopped in Windows Recovery with error 0xc0000189 and a system-capability
message. This is not a driver bugcheck or proof of driver incompatibility. The
failed disk state was retained as hvci-boot-failed-20261009; restoring the owned
licensed-ci-verifier-20261009 snapshot returned the guest to normal Windows boot.
Read-only WHvGetCapability returned S_OK: host HypervisorPresent, LocalApicEmulation
and ProcessorFeaturesBanks.Bank1.NestedVirtSupport are true. This does not prove
QEMU's partition setup or guest VSM boot. Missing host nested/APIC support is not
the observed explanation. The current guest has not demonstrated active VSM/HVCI. Repeating
registry settings is not a demonstrated remedy; host security was not changed.

Passed: optional new-VM UEFI preparation has fixed readonly code and private
mutable NVRAM paths, with pinned firmware hashes verified against selective
extraction from the checksum-pinned QEMU installer. BIOS remains default; three
existing BIOS metadata records passed read-only compatibility checks. Inert
expansion of the actual unattended XML verified EFI300/MSR16/Windows partition3
and unchanged BIOS layout. The new UEFI guest subsequently installed Windows
and reached the identity-checked pre-driver preparation phase. Its before-driver
disk snapshot was created after both owned processes stopped. The DVD boot needed
the installation media's key prompt; choosing the DVD and immediately sending
Space reached the installer without firmware or host policy changes. Real HVCI
remains unverified; UEFI boot alone is not its proof.

Passed: the final two-stage hibernate runner's 103 inert/native ABI checks also
passed under Windows PowerShell 5.1. It requires the original boot/logon/session, paired real
S4 events, healthy original device and post-resume PCM16/PCM32 capture. Both
independent read-only reviews passed after fixing a P2 stale-success report:
verification now invalidates the previous result before attempt-specific reads.
Five regression fixtures retain Findings when snapshot/ACL/hash/event/capture
reads throw. The first real preparation rejected missing logon-SID evidence before
any power request. The collector now reads TokenStatistics.AuthenticationId from
the existing identity token, checks enabled Interactive/RemoteInteractive
membership, and rejects service/anonymous identities and reserved authentication
IDs in both collection and decision. No token is elevated, duplicated or modified.
The final correctness and security follow-ups passed independently after
replacing host-dependent fixture identity/session calls with deterministic mocks.
A child-exit/Kill race seen after S4 now suppresses only confirmed process exit;
live-process errors and timeout flags remain failures, and resources are disposed.
Four inert stop/race checks passed. Real S4
acceptance has not yet been established.

Passed: the new UEFI guest installed the driver and passed 104 kernel IOCTL checks
and 20 PCM16/PCM32 capture checks, with zero findings/unsupported formats. Normal
evaluation activation produced LicenseStatus=1 and about 90 days remaining. Its
licensed pre-HVCI disk and NVRAM were retained before the next offline-network
boot. These results precede HVCI activation; they do not prove HVCI compatibility.

Passed: a separate export of historical commit
3ba0c2b63234948600c9da9aa3ade5901f076f6f built the actual 0.5.0.0 source using the
pinned EWDK, then file-only test-signed its SYS/CAT. All 126 historical source
files matched Git blobs; independent correctness review verified provenance,
tooling hashes and the 12-file ZIP inventory. This is a genuine older kernel,
not a changed version label. Private signing files were removed; no host trust
store was changed. Different-version guest update/rollback is not yet accepted.

Passed: the guest-only historical transition runner and stopped-VM stager are
implemented. The initial runner passed 34 inert checks in each PowerShell runtime;
the real 13-file prepared payload passed hash, private ACL and canonical inventory
checks. Independent correctness/security reviews found a separator mismatch and
a destination-exists staging preservation risk; both were fixed and re-reviewed.
The runner requires old baseline, current upgrade, actual DiRollbackDriver and
final current restoration, with installed version/SYS hash and PCM checks at
each stage. Reboot or uncertain in-flight mutation cannot pass or start a recovery
mutation. These are preparation results, not accepted real guest transitions.

Passed: bounded identity settling and stage-specific failure evidence passed
61 inert checks each under Windows PowerShell 5.1 and PowerShell 7. Independent
correctness review found a P3 stale previous-stage observation; clearing the
context before each operation fixed it, and independent correctness/security
follow-ups reviewed the fix. Actual stopped-VM staging preserved the original
manifest through default replacement refusal and an injected publication failure,
then archived the verified old payload and published the new validated payload.

Findings retained: the UEFI guest's first active-Verifier short run lost one
480-frame PCM16 packet; its next extended run stopped at 38.265 seconds on a
capture position gap while steady producer underruns remained zero. Another
guest was undergoing hibernate/resume during these attempts. The test's capture
thread lacked MMCSS registration even though its dedicated producer had it.
Both short and extended consumers now register with MMCSS Pro Audio/HIGH or
fail closed; detailed invalid-packet and consumer drain timing are reported.
All previous continuity/freshness/queue/underrun limits remain unchanged. Six
native and six ASan groups plus 44 offline checks passed. The initial kernel
capture result is not retroactively erased.

Passed: the updated consumer tool completed an isolated BIOS guest run under
active Code Integrity Verifier: 60.001 seconds, 33 checks, zero findings or
unsupported formats. Producer and consumers registered with MMCSS; maximum
consumer drain gap was 11,051 us, write gap 13,392 us, IOCTL 3,081 us and minimum
steady queue 358 frames. Both clients recovered waveform and observed fresh
silence at both lifecycle transitions, with zero position/timestamp errors,
steady underruns or overruns. The intentional pause retained one total underrun.
This is a short synthetic kernel run with two clients in one process; UEFI,
one-hour, physical microphone and separate-application acceptance remain open.
Full GitHub push and PR CI passed for exact commit 60fab4b.

Passed: the isolated UEFI guest also completed the updated consumer run under
active Code Integrity Verifier: 60.005 seconds, 33 checks, zero findings or
unsupported formats. Maximum consumer drain gap was 9,203 us, write gap
12,637 us, IOCTL 2,823 us and minimum steady queue 381 frames. Both clients
had zero position gaps/timestamp errors, recovered waveform and observed two
fresh-silence transitions; steady underruns and overruns were zero. One total
underrun from the intentional pause is retained. VBS was 0 and HVCI inactive;
this run does not establish HVCI. Exact cbabf82 push and PR CI also passed.

Findings: the UEFI HVCI preparation preserved its original registry/BCD baseline
and persisted all five requested settings without a firmware lock. Cold boot
then stopped at Windows Recovery with the same 0xc0000189 system-capability
message seen in the BIOS guest. This is not a driver bugcheck, nor does UEFI
alone remedy the guest VSM limitation. Active HVCI capture remains unverified;
the failed UEFI disk and NVRAM are retained before baseline recovery. No daily
host security or certificate settings were changed.

Findings retained: the first actual historical transition completed old-version
DevCon update with exit 0 but the immediate installed-version read differed.
The guarded current restoration returned exit 1 (reboot required); acceptance
halted with NeedsReboot and no old capture, upgrade or native rollback pass.
Both logs reported successful installation, and the subsequent read showed
0.5.1.0/oem0.inf. This does not prove the old version ever bound. The stopped
guest disk and serial report were preserved before the next reboot.

Findings retained: the next cold preflight hit a five-second CIM timeout before
any driver or certificate mutation. A warmed retry reached old update, then
43 bounded observations over 30.497 seconds showed old SYS file identity and
Running service while Win32_PnPSignedDriver still reported 0.5.1.0. Capture did
not run; current restoration returned exit 1/NeedsReboot with its process evidence
preserved. This is a metadata discrepancy requiring native PnP corroboration,
not an accepted old-version capture or rollback. The second disk state was
retained as version-settle-needs-reboot-20261009.

Passed: native installed-driver metadata reader preparation passed 185 inert
checks each under Windows PowerShell 5.1 and PowerShell 7, including pure UTF-16
parsing, x64 ABI/C# compilation, published INF path limits, request pairing,
duplicate JSON keys and bounded child timeout. SetupDiGetDevicePropertyW runs
only in a protected, request-paired read-only guest child with a ten-second
limit. Installed native version plus published INF/SYS hashes and service state
drive acceptance; WMI version remains separate diagnostic evidence. This is
preparation. The following real guest comparison supplies that proof separately.

Passed: run d430ff7c-56a1-4ae4-b729-f32ea93baac7 verified the genuine historical
0.5.0 baseline through SetupAPI, published INF hash e9096173..., SYS hash
0b065b41... and the original Running device, then passed 20 PCM16/PCM32 capture
checks. WMI still reported 0.5.1.0 during that actual comparison; the provider
metadata was stale. Current-version DevCon upgrade returned exit 1/NeedsReboot,
so no upgrade capture, native rollback or final restoration was accepted yet.
The immutable pending report and stopped disk state were preserved before
booting to apply the upgrade. Exact 6126243 push and PR CI passed.

Passed / preparation: explicit Resume preserves immutable raw-byte checkpoints
for upgrade, native rollback and final restoration that require reboot. It binds
the original VM/run/instance, frozen source, actual later boot and historical
capture files; four ordered real captures and actual DiRollbackDriver evidence
are required for final success. The single approved legacy upgrade report has an
exact run/hash migration; other old reports are rejected. Both PowerShell 5.1
and 7 passed 185 native regression and 106 Resume inert checks. Whole-number JSON
elapsed-time portability, nonfinite/type/boundary rejection, the three-reboot
executor chain and byte-identical checkpoint preservation are covered. Independent
read-only correctness and security reviews passed on source fc5e5170...03333;
the detected Int64 settling edge case was fixed and rechecked. No real guest
Resume success is established by these fixtures. Frozen preparation:
artifacts/driver-test-signing/version-transition-resume-final-0b8bb97ea57447fb849e89e7339d206e/.

Passed / partial live transition: explicit Resume retained the original legacy
run and verified current 0.5.1.0 identity plus 20 actual upgrade capture checks.
The first native rollback attempt displayed Windows' default interactive dialog
and returned a child failure; apiRollbackVerified/currentRestored remain false.
Its serial/log screenshot and stopped guest disk are retained before restoring
the known pre-Resume snapshot for a separate corrected attempt. The laboratory
native call now uses Microsoft's documented ROLLBACK_FLAG_NO_UI; NeedReboot is
still returned explicitly, and no automatic restart is added. Failed child process
metadata and the immediate Win32 error are retained for diagnosis. This correction
does not turn the failed attempt into success. Exact e79182e push and PR CI passed.
[Microsoft rollback behavior](https://learn.microsoft.com/en-us/windows/win32/api/newdev/nf-newdev-dirollbackdriver).

Passed / preparation: the corrected NO_UI source adb94eec...43c3 passed 191
native and 121 Resume inert checks in each PowerShell runtime. The actual C#
rollback body executes with inert native leaves to verify flags=1, both reboot
outcomes, immediate error-code reporting and handle cleanup. Real Resume executor
fixtures verify failed child exit, timeout and output-limit evidence without
retry, restoration or false success. The previous flags=0 source fails the new
regression. Independent read-only correctness/security reviews and 303 safe VM
fixtures passed; no leaks found. Frozen preparation:
artifacts/driver-test-signing/version-transition-no-ui-final-5308283600784e7bbb88ed6975739fd1/.

Passed / actual different-version transition: the final serial report completed
the original run d430ff7c-56a1-4ae4-b729-f32ea93baac7 on the same owned VM
e49c7f67-9bb0-4984-acf8-acb088d8f799 with frozen runner adb94eec...43c3.
Its seven ordered stages include four independent actual captures: old 0.5.0.0,
upgraded 0.5.1.0, native-rollback 0.5.0.0 and restored 0.5.1.0. Each passed
20 checks, both PCM16/PCM32 formats and zero failures. Actual DiRollbackDriver
with NO_UI returned exit 0 in 5.09 seconds; forced old installation was not used
as rollback evidence. Final current restoration returned exit 1/NeedsReboot,
then an explicit Resume after a later boot passed the final capture. The final
report is Passed/complete with apiRollbackVerified/currentRestored=true and
rebootRequired/driverMutationUncertain=false; testOnly=true and
productionReady=false remain. Cold CIM preflight failures and the earlier
interactive-dialog failure remain preserved attempts; read-only preflight
retry retained the immutable checkpoint without driver or trust mutation.
An independent read-only audit matched this final evidence. Exact f074d78
push CI 37971061744 and PR CI 37971066834 passed. Evidence:
artifacts/driver-acceptance/version-transition-final-pass-serial.log.

Passed / read-only HVCI diagnostics preparation: DeviceGuard queries now use
a five-second operation timeout and retain typed, bounded available/required
security capabilities with explicit unavailable or malformed states. Fixed
Hyper-V-Hypervisor/System and DeviceGuard/Operational queries retain at most
32 warning/error events and 512 characters per message; log-query errors remain
Findings. Active HVCI still requires VBS status 2 and running service 2.
All 336 safe VM fixtures passed in PowerShell 7; the 33 focused inert diagnostic
checks passed in both Windows PowerShell 5.1 and PowerShell 7. The full host
fixture suite uses a pre-existing .NET-only QMP transport and does not compile
under Windows PowerShell 5.1; only the isolated guest diagnostics are claimed
compatible there. No host CIM, event-log, registry or driver query was made by
these inert checks. Two independent read-only correctness/security reviews passed.
The actual restored BIOS guest collection returned Diagnostics Passed with
VBS=0, configured/running services=[0], available properties=[7] and required
properties=[0]; both fixed warning/error event queries were empty. CPU firmware
virtualization, monitor extensions and SLAT still reported true. HVCI is Not run,
not Passed. This preserved baseline has HVCI disabled and does not contain the
failed boot's live DeviceGuard state; empty warning/error queries cannot explain
or clear the earlier 0xc0000189 loader failure. Evidence:
artifacts/driver-acceptance/hvci-diagnostics-actual-serial.log.
Evidence: artifacts/driver-acceptance/hvci-diagnostics-pwsh.log,
hvci-diagnostics-winps-focused.log and hvci-diagnostics-pwsh-focused.log.
Passed / diagnostic telemetry capture: the frozen BD7F8877...B3A1D5 tool
completed 60.001 seconds in the same isolated BIOS guest with active Code
Integrity Verifier. All 33 checks passed with two shared PCM32 clients,
PCM16/PCM32 format checks, producer/client reconnects and fresh-silence checks.
Steady underruns/overruns, timestamp errors and position gaps were zero.
The minimum steady queue was 158 frames; maximum write completion gap was
18,069 us, producer lateness 8 ms, IOCTL duration 3,363 us and consumer drain gap
8,831 us. The fixed 64-observation producer history was present. The one total
underrun occurred during the intentional lifecycle pause, not steady capture.
This short result does not resolve the retained 633-second failure or establish
one-hour acceptance. Evidence:
artifacts/driver-acceptance/telemetry-ci-60-result-serial.log.
Findings / actual diagnostic hour attempt: the same frozen telemetry tool
stopped at 503,706 ms with 33 checks, seven failures and process exit 1
(507.32 seconds). Both MMCSS registrations succeeded; steady underruns=1,
driver silence=173 frames, overruns=0, minimum steady queue=0. Maximum producer
lateness was 14 ms, completed write gap 17,934 us, IOCTL duration 7,355 us and
consumer drain gap 12,119 us. Both clients retained zero timestamp/position
gaps, but each reported one discontinuity; no planned lifecycle phase had yet
been reached. The final STATUS followed the last successful write by 21,331 us.
Its preceding STATUS had queue=407, then one 480-frame write: at most 887 source
frames (about 18.48 ms nominal) were available. The next STATUS observed
queue=0, underruns=1 and silence=173; its own duration was only 276 us. This
supports starvation during a late pending write and explains why the maximum
completed-write gap alone did not describe the failure. Exact kernel pull sizes
and the cause of scheduling delay remain unmeasured; no kernel fix, relaxed
acceptance gate or completed-hour pass is claimed. Terminal serial and stopped
disk snapshot telemetry-hour-503s-findings-20261009 were preserved after normal
guest shutdown. An independent read-only evidence audit matched the timing and
counter sequence. Evidence:
artifacts/driver-acceptance/telemetry-hour-terminal-serial.log.
Findings retained: the earlier requested one-hour run on the rebooted current
driver stopped at 632,893 ms with one steady underrun and 22 driver silence frames. Native PnP
reported 0.5.1.0 before capture; active Code Integrity Verifier targeted only
SesMicrophone.sys. Producer and consumer MMCSS registrations succeeded. Maximum
producer lateness was 10 ms, write completion gap 14,751 us, IOCTL duration
3,613 us and consumer drain gap 12,109 us. Both clients had zero timestamp errors
and position gaps; minimum observed queue reached zero. The final report has
seven findings and exit 1, so this is not a completed hour. Its serial result
and native-version screenshot are preserved. Aggregate timing does not identify
the underrun's root cause; fixed test pacing and occupancy compensation need
event-correlated investigation. No gate, reserve or driver package was changed.

Passed: diagnostic-only capture-tool revision adds a fixed 64-observation STATUS
history with relative QPC/deadline, write timing, queue/drift and driver counters.
The rejected counter observation is retained before publishing failure. Existing
10 ms pacing, priming, lifecycle and zero steady-underrun gates remain unchanged.
Release build and all 48 offline analyzer checks passed, including four history
capacity/wrap/failure-retention/snapshot checks; the changed analyzer's
AddressSanitizer test passed. Independent read-only correctness and security
reviews passed on source SHA256 c47602d1..., with no concrete findings.
This preparation neither explains the earlier underrun nor proves a new real
capture run. Evidence: analyzer-telemetry.{log,json}, telemetry-build.log,
telemetry-asan-test.log and hour-current-ci-633s-underrun-serial.log.

Passed / inert only: a separate ignored diagnostic harness used the actual
PcmRing/PCM-clock headers for ten invented scheduling profiles, each advancing
3,600 simulated seconds. All completed with exact received/capture frame counters
and zero silence/underruns/overruns. The 14,751 us producer-gap and 8/15 ms callback
catch-up models did not reproduce the live failure. This was about three seconds
of host execution, not ten actual hours or observed VM scheduling. Neither these
models nor controller correction values establish physical clock drift. Evidence:
diagnostic-inert-sim.{cpp,jsonl} and diagnostic-inert-sim-notes.md.

Passed: the second actual S4 attempt completed prepare/request (exit 0, 50.53 s),
then resumed the same boot, user authentication ID and session 1. Kernel-Power
42/record 1527 and Power-Troubleshooter 1/record 1537 paired Target/EffectiveState
5 from 14:47:03.9646323Z to 14:47:48.2753064Z. HibernateVerify returned Passed
with resumeVerified=true and post-resume PCM16/PCM32 capture: 22 checks, zero
findings/unsupported formats, fresh silence after producer close. This is an
actual hibernate/resume test, not cold-boot substitution. The guest exposes no
standby state; S3 and full WPF physical microphone/application recovery are
not established by this result.

Incomplete: the first resumed S4 attempt was interrupted by a later host shutdown
(User32 1074 at 2026-10-09T13:36:29Z). The guest disk and serial evidence were
retained before restoring the licensed pre-test snapshot. Its original session
could not receive final verification; this is not a passed hibernate test or an
established driver bugcheck.

Not run/completed at this source checkpoint: one-hour acceptance, active HVCI
capture, standby/full application recovery, separate receiving applications,
physical latency and Microsoft production signing. The guest exposes hibernate
but no standby state; cold boot is not sleep.
HVCI configuration preserves its first protected registry/BCD baseline and only
reports reboot required until actual VBS/running-service evidence is collected.
The production bridge wait after CancelIoEx was unbounded at this older
checkpoint; the bounded-cancellation section above records its replacement.
Daily-use readiness
remains false; the daily host security settings and saved user state are preserved.

Evidence: artifacts/driver-acceptance/{capture-ci-60-dedicated-producer-serial.log,
capture-hour-ci-first-failed-serial.log,activation-verifier-sleep-serial.log,
vm-fixtures-uefi-final.log,vm-fixtures-hibernate-reviewed.log,
vm-fixtures-token-final.log,winps-token-final.log,secrets-token-final.log,
vm-fixtures-transition-fixed.log,winps-token-transition-final.log,
native-consumer-final.log,asan-consumer-final.log,capture-consumer-offline-final.log,
uefi-ci-60-position-gap-serial.log,hibernate-resume-host-shutdown-incomplete-serial.log,
standard-user-pcm-capture-serial.log,capture-hour-host-reboot-incomplete-serial.log,
uefi-pre-driver-serial.log,uefi-initial-kernel-capture-serial.log,
uefi-licensed-ci-before-reboot-serial.log,ci-fe8590a-passed.log,
ci-3cfaea3-passed.log,native-tests-final.log,asan-final-tests.log,
security-final.log,core-after-timer.log,hvci-configured-and-registry-serial.log,
hvci-boot-lock.png,recovered-desktop.png}. See [DRIVER-ACCEPTANCE.md](DRIVER-ACCEPTANCE.md).

# 0.7.5-dev / isolated signing lab — 2026-10-09

Passed: file-only SYS/CAT test signing, explicit public-certificate CMS checks,
Windows SIP/strong catalog membership, fixed ZIP inventory, and 35 integrity /
actual cryptographic tampering checks. Ephemeral PFX loading avoids persistent
Windows keys; private signing files are deleted. No host certificate-store,
test-signing, Secure Boot, Memory Integrity or driver installation changes.
This self-signed lab certificate is deliberately rejected by the normal helper.

Passed: six CTest groups and six AddressSanitizer groups, including 24 offline
capture-analyzer checks; 110 managed checks, offline WPF/persistence/shutdown,
18 driver helper checks, eight unsigned-manifest regressions and 35 offline VM
control regressions plus four diskless QMP checks. The existing locked helper test output was avoided with a
separate output directory. Secret/dependency/static checks and latest-all lab
helper analyzers passed. No UI design changed in this checkpoint.

Passed: SYS CodeView GUID and age match the full PDB; generated unsigned CAB
contains exactly four VeyloMic members and extracted contents match the snapshot.
This is an unsigned submission draft, not an uploaded or EV-signed submission.

Passed: Windows 11 IoT Enterprise LTSC evaluation build 26100 installed on an
owned QCOW2 with WHPX. The guest prepared its test certificate/policy and shut
down; the offline `before-driver` snapshot was listed before installing the
driver. DevCon installation returned zero; 104 running-kernel IOCTL checks
reported zero failures. Shared WASAPI PCM16 and PCM32 passed 20 checks: 94,560
deterministic signal frames, 10,560 fresh silence frames after producer close,
252 written packets and 319 captured packets. That successful capture run used
an interactive guest user with a non-elevated token; the initial IOCTL run used
the SYSTEM startup task. Neither used the daily host microphone.

Passed: Driver Verifier standard checks (active flags 0x001209bb, only
SesMicrophone.sys) with another 104 IOCTL / zero failures and 20 WASAPI /
zero findings. The verifier run captured 94,080 signal and 10,560 silence
frames in both formats. This is a short functional run, not an HVCI or endurance
certification. Verifier code-integrity checks were not enabled.

Passed: DevCon removed one driver device and reinstalled it successfully in
the guest. After a cold resume, another 104 IOCTL checks and 20 PCM16/PCM32
capture checks passed (94,560 signal and 10,560 fresh silence frames).
This follow-up does not establish continuous Verifier coverage across reboot,
sleep/wake behavior or upgrade/rollback compatibility.

The first capture run failed because Sleep(1) advanced the 10ms producer only
once per default clock tick: both formats reported 51ms lateness at 141ms.
A private high-resolution waitable timer corrected the harness, preserving
the 50ms deadline and all waveform/timestamp/silence acceptance criteria.
No kernel change was made to obtain this result. Guest UAC, initially absent
TrustedPublisher store initialization, ISO cold resume, JSON timestamp type,
and concurrent IPC file replacement races were also fixed and regression-tested.

QEMU uses private redirected stdio control, no TCP listener, no guest network,
no host device passthrough and only the owned read-only seed. Independent
read-only correctness and security reviews passed, including follow-up passes
on actual launch/contention and capture-harness fixes.

Not run: HVCI, extended lifecycle,
shared receiving applications, one-hour timing and Microsoft production signing.
The lab's 90-day Windows evaluation was explicitly authorized by the user.
The installed offline guest displays an expired-license watermark; activation
and an active 90-day license were not demonstrated. This limits long-duration
lab claims; no activation workaround or host licensing change was applied.
The older Microsoft ISO checksum PDF differs from the current official download;
two official HTTPS downloads and setup.exe publisher verification support the
recorded local pin, not a claim of matching the published PDF checksum.
The daily VB-CABLE route remains available; real user state hash was unchanged.
# 0.7.4-dev / driver 0.5.1.0 readiness — 2026-10-08

Passed: checksum-pinned EWDK 26100.6584 kernel build with WDK recommended
analysis/W4/WX, InfVerif /w and Inf2Cat; no compiler/analysis/INF warnings or
errors. Generated SYS/CAT are unsigned and were not installed. Manifest schema2
binds current ABI5/protocol1/INF version to four fixed payload hashes; repeated
builds cannot hash their own previous manifest. Explicit isolated-lab ZIP is
separate from the normal portable/Setup flow.

Passed: five native tests and their AddressSanitizer run, 110 managed checks,
offline WPF/persistence/shutdown/automation, 18 read-only driver helper checks
and eight package-integrity regressions. Shared driver validation covers invalid
formats, aligned notifications, integer timing across long suspend, and bounded
reserve/drift/jitter. These are portable models, not running-kernel acceptance.
The 20ms synchronous burst stress reports five bounded queue drops, zero silence;
the production source drains DMA every1ms. Do not infer arbitrary scheduler
stall tolerance or full-route latency from those fixtures.

Passed: helper preflight verifies exact INF, bounded held file handles, trusted
machine-context Microsoft catalog chain and Windows SIP-hash INF/SYS catalog
membership before reporting ready. OS driver installation policy remains the
final kernel-signing gate. Temporary elevated staging only removes its own GUID
and fixed files; removal snapshots devices and deduplicates OEM INF identities.
Dependency/secret/static scans and analyzers passed. Two independent read-only
Sol correctness/security reviews found no remaining confirmed high/medium issues.
One local test-output process remained locked after an initial interop-size test
fixture assertion; repeated tests used a separate output directory and passed.
No security policy/certificate store was changed to work around it.

Not run: actual Microsoft-signed positive package, kernel KS/IOCTL/PnP/sleep tests,
HVCI, Driver Verifier, receiving applications, full-route performance and signed
production driver packaging. No isolated lab is available. The daily machine's
VB-CABLE routing, running application and state.json were preserved byte-for-byte.
A separate Windows target and Microsoft signing prerequisites remain blockers.
See DRIVER-LAB.md; this checkpoint does not complete the own-driver transition.

# 0.7.3-dev calibration and profile checkpoint — 2026-10-08

Passed: 10-second quick calibration (2 seconds room / 8 seconds natural speech),
optional 20-second detailed stages, bounded bad-input rejection, preserved quick
EQ/HP/de-esser and full-wet cleaning, independent sensitivity preservation,
apply/undo and saved-device handling. Pending UI edits flush before analysis.
Four native tests and 110 managed checks passed, including real native DSP
profile probes with RMS-matched spectral separation and finite limiter-bounded
full-chain output. These synthetic signals are not perceptual voice-quality scores.

Passed: offline WPF smoke, profile settings reaching the controls without autoplay,
empty-preview navigation, calibration apply/undo, persistence, shutdown and four
unsigned/untrusted catalog rejection checks. 42 TR/EN layouts at 1160x840,
780x650 and 640x480 passed automated checks; actual desktop/compact calibration
and profile renders were inspected. Real user state SHA-256 was unchanged.

Passed: dependency/secret/static analysis and managed analyzers. Independent
read-only correctness and security reviews found no code/security issues; one
inaccurate documentation section label was corrected.

Not run: subjective listening with a real microphone, real Narrator/physical DPI
changes, receiving-application speech acceptance and full-route performance.
Installer/CI/release acceptance is reported separately in the GitHub run/release.

# Veylo 0.6.12 rebrand checkpoint — 2026-10-08

SES is now **Veylo**. Current application/window/tray/dialog/resource branding,
exe/assembly and helper identity, icon filename, preset export name, current
guides and new package names use Veylo. Turkish uppercase SES meaning sound in
labels such as SES AYARLARI is ordinary language, not the old product name.
The driver INF now advertises Veylo Project / Veylo Mikrofon. Native DSP bytes,
C ABI, device marker, service/IOCTL/hardware IDs and JSON schema remain compatible.
Existing state, opt-in Run preference and single-instance mutex retain legacy
identities; see [BRANDING.md](BRANDING.md). Historical checkpoints below are kept
with their measured filenames. Old archives and already-installed device names
are not rewritten by this rebrand.

**Passed:** Release desktop/helper builds with zero warnings/errors;99 core/native
wrapper checks including legacy-to-Veylo startup target upgrade, unsafe-target
rejection and downgrade prevention. Isolated self-contained10.0.11 desktop tests
exit0 in normal and verify-quit modes: actual Veylo window/assembly identity,
TR/EN automation peer names, persistence and offline shutdown regressions.
No microphone capture, user-state write or actual startup registry edit is used.
Pinned EWDK driver rebuild, WDK code analysis, INF validation and CAT generation
completed without errors/warnings. The driver is unsigned, not installed and
not validated in a kernel lab; this is development evidence only.

Evidence: artifacts/rebrand/{before-source.zip,change.patch,normal-terminal.json,
verify-quit-terminal.json}; build/driver/{build.log,infverif.log,inf2cat.log}.
Packaged offscreen WPF smoke exited0. Actual1120x820 Turkish and compact780x650
English renders were inspected; Veylo branding is visible without clipping.
The smoke covers navigation, localized controls, calibration/driver layouts,
reduced-motion and shortcut conflict/rollback paths. It does not start a live
microphone or establish real Narrator/DPI/device/game acceptance.
New app compatibility, runtime performance and broad device acceptance are not
inferred from naming checks. User-confirmed noise quality remains as reported.

# Scope clarification and user feedback — 2026-10-08

The user reports: "sesler suan temizlenmis sikinti yok". Noise cleaning is now
user-confirmed for their current setup. The feedback does not identify a build,
preset or controlled quiet-speech/desk-impact protocol; earlier instrumented
voiceQualityVerified=false fields remain historical measurement facts.

SES is a general Windows microphone/voice utility for recording, streaming,
meetings, communication and games. Discord and Valorant are compatibility
examples; they do not define core quality acceptance. Historical checkpoints
below retain their original app-specific scope. Current scope is in PLAN.md
and current acceptance boundaries are in ACCEPTANCE.md. No product code or
audio setting was changed by this documentation update.

The earlier 0.6.8 hour is now terminal: 3600.688309s, exit0, zero underruns and
overruns, CPU0.174048%, OS lifetime peak148312064 bytes. It was muted/instrumented
and normalProductBaseline=false. A normal0.6.10 process overlapped the last
approximately24 minutes; its audio activity was not verified. Its separate
119-sample external observation saw only a visible window, so the hidden-memory
target remains unassessed. Evidence: artifacts/hidden-ui-probe/
{HOUR-RESULT-20261008.md,live-068-hour-observed-terminal.json,
live-068-hour-20261008-153655/live-final-metrics.json,
normal-0610-readonly-20261008-1638/result.json}.

# 0.6.11 development checkpoint — 2026-10-08

**Passed:** missing meter/progress accessibility names and hard-coded English EQ
names now resolve from Turkish/English resource dictionaries. Actual WPF
Automation Peer checks cover both languages and the production EQ template.
Removing Automation Name attributes makes old/new window XML identical: layout,
visuals, handlers and audio bindings are unchanged. Each dictionary has 290 unique
keys with matching key sets. The pre-fix test failed on the unnamed InputMeter;
the corrected self-contained .NET10.0.11 fixture exits0 in both normal and
--verify-quit modes. Existing persistence and offline-shutdown regressions pass.

The new Quit fixture invokes the real production exit method during a real
synthetic offline render. A controlled lifecycle barrier proves the late render
cannot publish its result/cache; releasing the barrier leads to Window.Closed,
Application.Exit and the closed native SafeHandle. No window is shown, microphone
opened, user audio played, tray/hotkey registered or real user state changed.
An initial timeout was a fixture error: all three shutdown events had occurred,
but its manually owned dispatcher frame did not stop on Application.Exit. The
fixture now ends that frame on the real event and retains a failing timeout.
This did not require a production shutdown change.

Build/analyzers have zero warnings/errors. Two independent read-only Sol medium
code/security reviews passed for names and the additional Quit fixture/script.
Core/native/DSP/ABI are unchanged. Evidence:
artifacts/accessibility-names/{change.patch,quit-test.patch,
before-terminal.json,normal-final-terminal.json,verify-quit-final-terminal.json,
semantic-verification.json}. [ACCEPTANCE.md](ACCEPTANCE.md) lists finite feature
acceptance boundaries, including the unverified whole-screen/system-audio
Discord duplicate-microphone scenario.

**Not run:** real Narrator, new full visual renders, actual150/200% display
transitions, physical tray click/active-device Quit, playback/file dialog,
real quiet speech/desk impacts, Discord/Valorant/FPS, physical latency,
unplug/sleep/second-PC acceptance. The separate0.6.8 muted one-hour process
is still running at this checkpoint; it is not0.6.11 live acceptance or a normal
product RAM baseline. The user deferred real Discord listening. dailyUseReady=false.

# 0.6.10 development checkpoint — 2026-10-08

**Passed:** an offline-render shutdown regression first failed on0.6.9
(exit1: result published after shutdown). UI continuations now discard render,
personal analysis and recommendation-preview results when quitting; recording,
playback/export entry guards and closing-control guards protect the same state.
Render captures a local sample snapshot. No DSP/ABI/native DLL change was made.

The expanded isolated desktop fixture passes on self-contained .NET10.0.11:
controlled pending-task completion for comparison/calibration, normal real
offline rendering and cache publication, closed-cache/playback entry rejection,
and no control re-enable during shutdown. It also repeats persistence tests.
Native live-engine Running/ProcessedFrames remain zero; no sound is played,
no dialog/microphone is opened, and user state is unchanged. Plain WPF dispatcher
work is pumped only after smoke mode is restored and all five timers are stopped.
This models the quitting state; it does not invoke actual tray Quit or establish
full Windows shutdown/sleep acceptance. Build/analyzers have zero warnings/errors.
Two independent read-only Sol code/security reviews passed without findings.
Evidence: artifacts/offline-shutdown/{change.patch,before-terminal.json,
runtime11-terminal.json,runtime11-stdout.txt}. Prior98 core checks concern
unchanged Core/native code; this turn adds focused desktop verification.

**Not run:** real voice/desk-impact listening, Discord/Valorant/FPS, physical
latency, unplug/sleep/accessibility/second-PC acceptance remain open. The separate
0.6.8 one-hour process is still pending; it is not a completed0.6.10 live test.

# 0.6.9 development checkpoint — 2026-10-08

**Passed:** a desktop persistence regression first failed on the previous code
with exit1: a failed profile write was reported as success. SaveState now returns
the persistence result; save/import/shortcut success messages respect it.
The new isolated desktop tests pass on self-contained .NET10.0.11 (exit0):
directory/atomic-replacement failures, successful save/import reloads and retry
without duplicate profiles. Native Running/ProcessedFrames remain zero; no user
state, audio capture, tray, global shortcuts or registry are used. The test runs
from scripts/test.ps1. Release/analyzers have zero warnings/errors;98 existing
managed/native-wrapper tests also pass. Two independent read-only Sol code and
security reviews passed with no findings. Global shortcut persistence was reviewed
in source; this new fixture does not register real global shortcuts.
Evidence: artifacts/profile-persistence/{change.patch,before-terminal.json,
runtime11-terminal.json,runtime11-stdout.txt}. Native DLL/ABI/DSP are unchanged.

**Passed / limited evidence:** prior0.6.8 low-overhead muted validation completed
600.895 seconds, zero underruns/overruns, CPU0.1744% and OS lifetime peak working
set142241792 bytes including startup. Its complete terminal report exists; the
launcher did not retain the process exit code. This passes those resource checks
for that instrumented run only, not the normal-product baseline or all previous
RAM failures. The separate0.6.8 one-hour process remains pending; its result is
not assumed for0.6.9. Evidence: artifacts/low-overhead/live-068-low-20261008-152454/.

**Not run:** real quiet speech/desk impacts, Discord/Valorant/FPS, physical40ms
latency, disconnect/sleep, accessibility and second-PC acceptance remain open.
The user explicitly deferred the Discord listening trial. No new noise-quality
or daily-use-readiness claim is made by this persistence fix.

# 0.6.8 development checkpoint — 2026-10-08

**Findings / interrupted:** prior0.6.7 PID15716 is absent; last progress2861.616s
had zero underruns/overruns and peak working set152137728 bytes. No final result
was written. Windows System event1074 at04:18:41+03 reports user-initiated shutdown;
event6006 follows at04:18:48. Current boot is09:20:56+03. This is not a completed
one-hour test or evidence of an application crash. Prior state/terminal placeholders
remain preserved in artifacts/game-span/live-067-hour-20261008-033054/.

**Findings:** read-only startup audit found HKCU Run/SES still targeting0.1.0;
the separately running application is0.6.0. Current development output fixes
normal startup registration refresh while preserving existing enablement.
No running application is killed or restarted by that repair.

Low-overhead validation lowers diagnostic polling/writes and records metadata
GC counts/current working set/lifetime peak; it remains instrumented and cannot
establish the exact normal-product RAM baseline. The OS lifetime peak includes
startup. Physical latency, actual speech/desk impacts, Discord/Valorant/FPS,
unplug/sleep and second-PC acceptance remain outstanding.

**Passed:**98 managed/native-wrapper checks, Release build/analyzers zero
warnings/errors, packaged WPF smoke and invalid low-alone/repair+validation
command rejection (exit1 before state/audio). Two independent read-only Sol
correctness/security reviews completed; a progress-serialization field-loss
finding was fixed and re-reviewed. Both live timelines retain Version1/Size96
and actual callback/FIFO fields. Startup-only repair exited0 and changed the
existing0.1.0 target to0.6.8; current0.6.0 PID25212 and user state hash remained
unchanged. Evidence: artifacts/low-overhead/{repair-result.json,ui-terminal.json,
invalid-low-alone-terminal.json,invalid-repair-validation-terminal.json}.

**Findings:** two concurrent muted35s live runs had zero underruns/overruns,
but resource acceptance correctly failed(exit1). Low mode35.3016s/35 observations
had OS lifetime peak165527552 bytes; full35.0327s/320 observations165441536 bytes.
CPU0.2361%/0.2825% and GC counts0 in both. These are short concurrent diagnostic
runs, not controlled performance comparisons or proof of a retained-memory leak.
Earlier152MB values were sampled peaks excluding the unobserved startup peak;
do not compare them as evidence of a memory regression or improvement.
Low mode wrote2 timeline lines; full mode4. No raw samples were saved.
Evidence: artifacts/low-overhead/short-{low,full}/.

# 0.6.7 development checkpoint — 2026-10-08

**Passed / limited evidence:** self-contained .NET10.0.11 metadata-only probe
compared394 real processes and7296 synthetic policy combinations. Names, order,
fullscreen flag and first-match behavior were equivalent; native layout was
568 bytes/name offset44/no managed references. Across100 polls after warmup,
scan+policy allocation fell from58912 to32 bytes/poll; custom-match144 bytes.
UI Task.Run/custom-list snapshot and retained working set are excluded.
1000 further scans had no handle-count increase. Evidence: artifacts/game-span/
probe-runtime11/probe-result.json; repeatable probe source/project in probe/.

**Passed / limited evidence:** exact unchanged production native DLL
DE130AD2158E9D1B4A0D1B481AC9C8EC95B6343EEC2A402915FB930DE426E67C
ran a muted-before-start5ms request with20ms buffer for600.070565 seconds.
28802880 frames, zero underruns/overruns, sampled output silent. Physical USB
capture period480 frames/CABLE render240 frames at48kHz; callbacks240 frames.
This was a native CLI test, not full-app CPU/RAM, speech or end-to-end acceptance.
Sampled buffer estimate31.417..51.521ms is not physical/differential latency.
Evidence: artifacts/endpoint-periods/control-long-{handle.json,results.jsonl}.
The process is terminal; its exit code was not retained by the background launcher.
An additional48-case240-frame waveform/clock/jitter oracle passed with no
buffer or invalid-source errors; modeled source age still can exceed40ms.

**Findings:** previous0.6.6 hidden/muted validation completed3600.090168 seconds,
zero underruns/overruns, CPU0.1592%, peak working set152023040 bytes. Memory
target150000000 failed. Validation instrumentation was active; this is not a
normal-product RAM baseline. A separate5ms silent co-client experiment ran
during part of the hour; do not interpret it as an isolated endpoint-period run.
No forced collection, working-set trim or GC override is shipped.
Evidence: artifacts/memory-policy/live-066-hour-20261007-201041/live-final-metrics.json.

**Passed:** current-release Release build/analyzers had zero warnings/errors;
91 managed/native-wrapper checks passed. Expanded288-case FIFO jitter matrix
passed in regular and AddressSanitizer builds. Packaged WPF smoke passed routing,
game-mode effects/continued audio, hide behavior, selection/translation and
invalid-state mute checks. UI evidence: artifacts/game-span/ui-067/.
Two independent read-only Sol correctness/security reviews passed. The code
review found a diagnostic oracle exit-code issue; it was fixed to fail on any
buffer loss, retested48/48 clean, and independently re-reviewed by both reviewers.
The unchanged native DLL was supplied explicitly from build/stream-stability/bin;
the older build/bin DLL was not packaged. No voice recording was written.

**Not run:** actual quiet speech/desk-impact listening,
Discord/Valorant/FPS, physical latency, disconnect/sleep and second-PC acceptance
remain unverified. The user has not tried strong cleaning on quiet speech yet.

# 0.6.6 development checkpoint — 2026-10-07

**Passed / limited evidence:** game-policy benchmark preallocates 350 ordinary
non-game observations and compares 1000 polls after warmup. Both empty and
20-name custom lists fell from 42032.04 to 32.04 allocated bytes per poll.
This excludes process enumeration, observation construction and retained RAM.
Timing was 64.7065 → 50.4932 ms for the empty list and 114.6276 → 190.456 ms
for 20 names over 1000 polls; the latter is a small CPU tradeoff, not a speedup.
89 managed checks passed including custom `.exe` matching, fullscreen exclusions
and process-name validation. Native DSP/ABI are unchanged in this revision.

**Findings:** exact 0.6.5 PID29356 completed its 600.033-second physical
USB microphone → VB-CABLE run. Zero underruns/overruns, CPU0.1964%, sampled
DSP p95≤0.33ms/p99≤0.40ms, peak working set151572480 bytes. The150000000-byte
memory target failed, so overall acceptance is false. This was a muted,
hidden quiet/ambient validation run, concurrent with a separate baseline;
it is not speech listening, game-load or physical end-to-end latency evidence.
Artifacts: artifacts/fifo-phase/live-065-20261007-194757.

**Not shipped:** a separate 0.6.5 child-process GCConserveMemory=5 experiment
is separate from this release. No GC override, forced collection or working-set trimming
is included in 0.6.6; no result is assumed from the experiment's progress.
User has not yet tried strong cleaning on quiet speech/word starts.

**Passed:** two independent read-only Sol reviews of the scoped policy, test,
version, documentation and benchmark found no correctness/security issue.
Release build/analyzers reported zero warnings/errors. Actual game/FPS,
quiet speech, desk-impact listening and full 0.6.6 live acceptance remain unverified.

# 0.6.3 development checkpoint — 2026-10-07

**Passed:** packet-clock regression uses the production FIFO for eight virtual
hours (±600ppm, four phases); causal interpolation is compared against a
non-periodic oracle at both±1000ppm servo limits through240/480/720 partitions
and ring wrap. True capture gaps still fail and emit silence. Four native and ASAN suites passed after the final RNNoise backport;
88 managed checks and Release/analyzers passed. Existing WPF integration smoke
passed navigation, native mute, personal calibration apply/undo, advanced input
handling and game visual policy while audio frames continued. Final verification
is recorded under artifacts/stream-stability.

**Findings:** old physical one-hour run stopped before a terminal report (PID35760):
at2619s35 underruns, peak156835840 bytes. The PI/future-looking candidate
(PID31340) also failed; at1004s24 underruns and152461312-byte peak. Both process handles are now absent and their reports remain stale running;
no completed-hour claim can be made. These runs are not acceptance passes. Candidate diagnostics showed one source sample plus
one remaining output at starvation. Causal interpolation removes dependence on
an unpublished future sample. Its600-second physical run (PID14756) completed with3 true underruns
(last starvation had0 source frames and3 remaining outputs) and156377088-byte
working-set peak, failing both stream and memory targets. The final0.6.3
30-second run passed:0 errors, CPU0.347%, peak139116544 bytes. A short run does
not supersede the failed long run. Long-run and performance success are not claimed. All validation processes contribute only
silence; samples remain RAM-only and user settings are unchanged.

**Passed / limited evidence:** process-only game detection reduced per-scan
managed allocation~92% on this host, with~3ms scan-time cost. This is not retained
RAM savings. Independent review found cached HandleCount evidence; it was
withdrawn. Uncached native measurement now shows current0 handle delta and
333/333 process-name parity; old+2 is unexplained, not an established leak.
Both independent code/security followup reviews passed the FIFO/interop fixes.

**Findings:** isolated official RNNoise gain-decay backport A/B uses the same
v0.2 full model. Some keyboard tails improved, two strong events increased
~0.15/0.23dB and the desk-impact peak was unchanged. Clean/soft harmonic proxies
were almost unchanged; these are not real voice preservation tests. The upstream
backport is included as a limited bug fix, with source checksum/license notice;
no model/frame/GPU was added. Real desk noise/Turkish speech/Discord listening,
physical end-to-end latency, game FPS, unplug/sleep and second-machine validation
remain **Not run**. This is a development release, not daily-use acceptance.

# Live acceptance work — 2026-10-07 (goal active)

**Passed:** Explicit live-validation mode now contributes silence before first
capture start, retains fresh smoke-only settings, and accepts1..3600 seconds.
Core86 tests cover duration rejection, percentile-overflow reporting and final
counter rollback/mute guards. Release/analyzers zero warnings/errors.
Ten-second actual physical microphone -> VB-CABLE test passed:480960 frames,
zero underruns/overruns; CPU0.675% of total system, peak working-set148389888
bytes and private101416960 bytes. This quiet/ambient run is not voice/game
performance acceptance. User state SHA256 was unchanged. Samples remain RAM-only.

**Passed:** Independent Sol correctness/security reviews of this scoped harness.
Three P2 evidence issues were fixed and re-reviewed: histogram overflow, final
counter reset, and stale prior success after failure. Gitleaks found no app leaks.
Metrics are sampled at10Hz, not every DSP block; percentiles are upper-bound
buckets and overflow becomes null+count. Each report has a current runId/status.
Other apps' CABLE audio is not silenced; only the test process contributes zero.

**Running / not accepted:** One-hour physical capture/render test started via
artifacts/live-acceptance/hour-handle.json. Completion requires that exact process
or its terminal report be inspected; progress is not completion. At140.7s the
working-set peak was155140096 bytes: the150MB memory goal is already exceeded
in this instrumented run and is a finding even if the stream completes. At301s
eight underruns were also observed: zero-buffer-error acceptance is already
contradicted. The exact process continues for characterization, not a green pass. Current tests
have not verified unplug/replug, sleep/wake, speech quality, Discord/Valorant
listening, game FPS, real end-to-end latency or second-PC acceptance.

**Findings:** Official DFN3/DFN3-LL native Windows offline probes ran on synthetic
20-second fixtures. Standard model's40ms window/lookahead plus current20ms buffer
exceeds latency target; LL CLI working set~189MB exceeds total hidden150MB target.
These are staged experiments, excluded from app packages and runtime. Speech
preservation and real desk-impact quality remain unproven. Source/license/hash
and limitations: artifacts/denoiser-probe/README.md. No driver/global tools installed.

# 0.6.2 — validation recovery and audio decision timing

**Passed:** Release/analyzers zero warnings/errors; three native suites (DSP183
checks), managed82 regressions and four driver-catalog rejection checks. New
regressions first failed on the old implementation: zero-hold short-word tail
and AGC gain during delayed silence. Level history now covers the emitted frame
and existing20ms lookahead; no extra inference/audio delay or VAD queue added.
WPF smoke verifies actual native mute after invalid EQ (with/without bypass),
strong-clean validation recovery, pending/profile-save flush, and failed WAV
write without engine shutdown. Personal apply/undo refreshes last-valid state.

**Findings:** Prior offline test metrics could remain published at live start
until the first callback, making session frame comparisons use the old counter.
Live open now publishes reset counters/silent levels before capture starts.
A stale earlier crashed test runner locks the normal build/test outputs on this
host; the final build uses build/continuation and isolated managed outputs.
No user application process was stopped to work around it.

**Not run:** Real Turkish quiet-syllable/desk-impact listening; end-to-end Discord
and Valorant; measured latency/FPS/one-hour physical clocks and reconnect; real
DPI/Narrator and lower-powered PC. Desk-impact suppression remains unsolved.
A rejected experimental impact heuristic is excluded from this release.
Custom driver signing/kernel lab remain deliberately deferred; VB-CABLE remains
the normal route. The all-features goal is active, not accepted as complete.
Evidence: artifacts/continuation-audit (before snapshots, scoped patch, UI,
test logs and reviews); docs below retain historical evidence and limitations.

# 0.6.1 — güçlü temizleme düzeltmesi
**Passed:** 82 managed tests, native DSP174 checks and three native suites,
4 catalog rejection checks, build/analyzers zero warnings/errors, WPF strong-clean
button interaction (full wet, expander, manual mute preserved, recording guard).
Keyboard-like synthetic fixture: mixed RMS0.00072697 vs full-wet0.00004880 with
AGC off; not a real keyboard/voice recording. Stationary, chirp/delay, limiter,
mute/bypass and previous UI/routing regressions remain covered. ABI5 unchanged;
no new dependency/model/kernel work. Factory presets and normal startup unchanged.

**Not run:** User's real Discord listening, voice+typing quality, quiet consonants,
full game/FPS/latency/one-hour physical device tests. This is full-wet configuration
and residual-background expander, not new speaker-isolation AI. Prior 0.6.0
performance evidence below is historical; no new performance claim.

# 0.6.0-dev — useful controls with VB-CABLE

**Passed:** Release build/analyzers (0 warnings/errors), 80 managed regression
checks, native DSP166 checks + resampler/transport suites, four driver catalog
rejection checks, packaged WPF smoke including TR/EN desktop/640x480 renders,
expander/settings controls, fixed factory shortcuts, real Windows hotkey
registration/conflict/rollback cleanup. No physical key injection/simulation.

**Passed:** Independent read-only Sol correctness and security reviews. One P3
stale test comment was corrected. No remaining concrete findings in task scope.
Gitleaks found no secrets; checksums85 verified; NuGet lookup no vulnerable
packages; OSV miniaudio WAV decoder advisory is not affected (decoder compiled
out, verified preprocessed TU); Clang's two existing upstream dead stores were
reviewed informational. No new dependency was introduced. No driver installed.

**Findings / limits:** First packaged 30-second hidden VB-CABLE run opened and
continued (1,555,200 frames), but had one underrun while UI smoke also ran.
Input was -120 dBFS, so this is stream-continuity evidence, not speech quality
or suppression performance. Quiet-run CPU0.154% of total system, max working
set137.65 MiB on Ryzen5 7600; not game/voice-load measurements. A sequential
repeat passed: 1,557,120 frames, zero underruns/overruns, CPU0.240%, max136.45 MiB;
input again -120 dBFS. Original evidence is retained.

**Not run:** Physical-key press/release in actual games, lock/sleep/secure
 desktop behavior, real Discord/Valorant listening, one-hour drift, FPS/1%low,
end-to-end latency, 150%/200% DPI and second lower-powered PC. No claim of speaker isolation,
AEC or AI microphone restoration. Custom driver signing/lab remain outstanding;
VB-CABLE mode needs no SES driver. Earlier release evidence below is historical.

Evidence: artifacts/useful-features/package-ui, package-live,
package-live-sequential; artifacts/security. This release uses ABI5 and driver
protocol1. Existing profiles/calibration and VB-CABLE routing are retained.

# 0.5.2 VB-CABLE restoration

Output policy, old-state migration, missing-device behavior and real WPF route
selection are covered by regression tests. Desktop/native ABI4 is unchanged.
71 managed regressions, native DSP/resampler/transport suites and four catalog
rejection tests pass. WPF selection/translation/game-mode checks and a real
30-second physical-microphone -> CABLE Input run pass; zero buffer errors in
that run. This validates stream opening/continuity, not listening quality or
measured end-to-end latency. Gitleaks and managed analyzers pass. Independent
code/security reviewers found recovery/privacy/feedback issues, fixed and
re-reviewed; no remaining finding in that task scope.
Latest evidence: artifacts/vbcable-restore and artifacts/package-0.5.2-ui.
Real Discord/Valorant and screen sharing remain manual acceptance checks; the
custom SES driver is still unsigned/unvalidated in a kernel lab.

# SES doğrulama — 2026-10-07

## 0.5.1-dev — cam arayüz ve otomatik oyun modu

Build/analyzers: sıfır uyarı/hata. Core60 kontrol (7 yeni oyun politikası/girdi/
kalıcılık testi); katalog4 ret kontrolü. Native96/transport72/resampler önceki
motorla geçti; ses motoru ve sürücü bu UI değişikliğinde değiştirilmedi.

Gerçek WPF render: TR/EN,1120×820 ve640×480; navigasyon simgeleri, ölçerler,
beş profil, kalibrasyon ve sürücü ekranı. Dar pencerede yatay taşma kontrolü.
Oyun gözlemi kontrollü enjekte edilerek aktif/kapalı/geçiş/geri dönüş test edildi:
çalışan hover animation clock'u durdu; cam arka plan kapandı; ölçer200ms oldu;
mikrofon capture kareleri ilerledi; ayarlar değişmedi. Elle efekt kapatma,
pencere gizleme, maximize/restore, süreç listesi ret/kaydet test edildi.
Gerçek süreç metadata okuyucusu çalıştırıldı; kendi SES işlemi hariç tutuldu.
artifacts/ui/experience-result.json ve glass-*.png / game-*.png kanıttır.

Bu makinede Windows ClientAreaAnimation=false. Normal sürüm buna uyar. Yalnızca
--smoke görsel testinde animasyonlar açılarak normal görünüm ve iptal yolu
sınandı; Windows ayarı veya kullanıcı state.json değiştirilmedi. Fiziksel
%150/%200 monitör/DPI geçişi ve gerçek oyun algılama/FPS/frametime testi yapılmadı.
Oyun modu bir render politikasıdır; sürücü eksikliği ve aktarım durumunu değiştirmez.

## 0.5.0-dev — otomatik çalışma ve kendi capture sürücüsü

Bu çıktı geliştirme sürümüdür. Sürücü imzasızdır ve günlük bilgisayara kurulmamıştır.
EV sertifikası/Hardware Dev Center hesabı, Microsoft üretim imzası ve ayrı Windows
10/11 laboratuvarı tamamlanmadan günlük kullanıma hazır kabul edilmez.

| Kontrol | Sonuç ve sınırı |
|---|---|
| Release uygulama/helper build | Hatasız; ABI4/UI-DLL birlikte teslim edilir |
| Native DSP | 96 kontrol ve resampler testi geçti |
| PCM aktarım testleri | 72 kontrol: boyut/format/sahiplik protokolü, PCM16, taşma, zaman aşımı, eski sesi atma, SPSC eşzamanlılık ve sentetik bir saat |
| AddressSanitizer | Native üç test grubu geçti; kernel çalıştırma değildir |
| Managed | 53 kontrol: eski profil uyumu, giriş seçimi, kayıtlı cihazı bekleme dahil |
| WPF | Beş preset, kişisel kalibrasyon/uygula/geri al, duyarlılık, TR/EN,640×480 ve sürücü yardım ekranı |
| Gerçek yerel mikrofon | USB PnP Audio Device ile otomatik/gizli açılış, kapatınca gizlenme ve örnek bitince işleme sürmesi doğrulandı |
| EWDK sürücü build | Sabit26100.6584 araç zinciri; DriverRecommendedRules analizinde sıfır uyarı |
| INF/katalog | InfVerif ve Inf2Cat geçti; katalog oluşturulması imzalama değildir |
| Güvenlik | Gitleaks,85 kullanıcı-alanı bağımlılık hash kontrolü, Clang/.NET analizi ve NuGet/OSV sonuçları incelendi; ayrıntı SECURITY.md |
| Katalog reddi | 4 test geçti: bozuk, sahte Microsoft isimli self-signed, çoklu signer ve imzasız geliştirme CAT. UAC/kurulum yapılmadı |
| Kurulum yardımcısı | Derlendi; günlük makinede yalnızca read-only status çalıştırıldı. UAC kur/güncelle/kaldır/geri al henüz laboratuvarda denenmedi |
| Microsoft üretim imzası | Yok; geliştirme SYS/CAT imzasız, kurulum etkin değil |
| Kernel/laboratuvar | Driver Verifier, HVCI, Win10/11 cihaz/uyku/çökme/güncelleme senaryoları henüz çalıştırılmadı |
| Discord/Valorant | Yeni SES Mikrofon üzerinde eşzamanlılık, ekran paylaşımı ve Vanguard uyumu doğrulanmadı |
| Performans kabulü | Tam imzalı akışta CPU/RAM/gecikme, FPS/frametime ve ikinci sistem ölçümü yapılmadı |

Yerel kısa performans deneyi (artifacts/ui/live-result.json):30 saniye gizli
pencereyle yalnızca capture/DSP çalıştı; sürücü durumu missing. CPU yaklaşık%0,19,
çalışma belleği tepe140MiB; tampon hatası yok. Giriş sessizdi. Bu ölçüm gerçek
konuşma, imzalı aktarım veya oyun yükü değildir; ≤%3/≤150MB/≤40ms hedeflerinin
kabulü olarak kullanılmaz. Uçtan uca gecikme ölçülmedi. Kernel ring için bir saat
sentetik test gerçek cihaz saat farkı veya bir saat Discord testi sayılmaz.

Secure Boot, Bellek Bütünlüğü ve test-signing ayarları değiştirilmedi. VB-CABLE
sürücüsü ve önceki0.4.1 çıktıları korundu; yeni sürüm bunlara otomatik yönlenmez.
Açıkça oynatılan karşılaştırma/Windows mikrofon dinleme sesi sistem sesi paylaşımında
duyulabilir; sürekli mikrofon akışının render yoluna bağlanmaması tek başına gerçek
Discord ekran paylaşımı kabul testi değildir.

## 0.4.1 Podcast preseti

Beşinci hazır profil ve Ses Kalitesi hızlı düğmesi eklendi. Release build
sıfır hata/uyarı; managed51 kontrol ve mevcut native96/resampler testleri geçti.
Yeni native zincir testi, sentetik sabit ortam örneğinde Doğal'a göre daha düşük
çıkış enerjisi ve ani seviyelerde sonlu/limiter sınırındaki çıkışı doğruladı.
Bu gerçek fan/klavye veya insan konuşması kalite ölçümü değildir. WPF beş
profilin uygulanmasını, Türkçe/İngilizce ve640×480 düzenini doğruladı.
artifacts/ui/podcast-tone-*.png incelendi. Paylaşılabilir podcast-preset.json
aynı factory ayarlarından üretilir; cihaz kimliği/ses içermez. Motor, ABI3 ve
bağımlılıklar0.4.0 ile aynıdır. Gerçek sesle dinleme/Discord/Valorant doğrulaması
bekliyor; dış sesleri tamamen silme veya herkes için ideal ton iddia edilmez.

## 0.4.0 giriş duyarlılığı

Manuel/otomatik bağımsız duyarlılık ve canlı eşik/giriş görünümü eklendi; ABI3.
Native96 kontrol ve resampler testi geçti: eşik altı çıkışın kapanması, üstü
geçmesi, mevcut20ms gecikmeyle ton başlangıcının korunması,300ms bekleme,
otomatik hafif konuşma koruması, eşik geçiş sınırı, manuel geri dönüş ve
bypass/mute/limiter davranışı dahil. Bunlar sentetik davranış testleridir.
Managed50 kontrol: eski profillerde kapalı varsayılan, sonlu/sınırlı değerler,
profil roundtrip ve gerçek native flag/eşik/kazanç geçişi dahil. WPF testi manuel
slider/otomatik kilitleme, geri dönüş ve gürültü azaltmadan bağımsızlığı doğrular.
TR/EN640×480 görüntüleri artifacts/ui/sensitivity-*.png altında incelendi.
Gerçek Türkçe konuşma/fan/klavye ve Discord/Valorant dinleme doğrulaması bekliyor;
bu sürüm için oyun FPS/CPU/bellek/gecikme performansı ölçülmedi.

Gitleaks,85 bağımlılık checksum/NuGet/OSV kontrolü, managed analiz ve Clang SAST
geçti; önceden incelenmiş iki upstream bilgi uyarısı dışında bulgu yok.
AddressSanitizer DSP/resampler kontrolleri geçti. Bu sürümün eşik kontrolü
Windows/Discord mikrofon ayarını değiştirmez; kendi ses çıktısına uygulanır.

## 0.3.0 kişisel kalibrasyon

Release build ve managed analiz sıfır hata/uyarı ile geçti. Native63 DSP kontrolü
ve resampler testi, managed46 kontrol geçti. Farklı mikrofon seviyeleri/ortam
seviyeleri/spektrumlar için farklı ve sınırlı öneriler; eksik aşama, DC, clipping,
NaN, büyük/kısa örnek, konuşma olmayan VAD ve kirlenmiş ortam reddi doğrulandı.
Gerçek RNNoise sessizlik analizi ve önerilen ayarlarla20sn native işleme sonlu,
limiter sınırı içinde kaldı. Yerel saklama, paylaşılan profilde cihaz/ses olmaması,
yanlış cihazda uygulamama, profil sınırları ve apply/undo izolasyonu geçti.

Gerçek WPF render/controller testi: dört aşama sınırı, uygulamadan önce ayarların
korunması, önerinin20ms gecikme eşitlenmiş A/B üretmesi, profil oluşturma, cihaz
ayarını yeniden yükleme, geri alma ve başarısız örnekte uygulamanın kapanması
doğrulandı. TR/EN640×480 ekranları artifacts/ui/personal-*.png altındadır.
Bu UI regresyonu sentetik örnek kullanır; kişisel konuşmayı kaydetmez/oynatmaz.
Gerçek kişilerde 20sn sihirbaz, sessiz Türkçe kelimeler, farklı mikrofonlar ve ton
tercihlerinin dinleme doğrulaması bekliyor. Kalibrasyon performansı oyun sırasında
ölçülmedi; aşağıdaki0.2.0 canlı ölçümü0.3.0 sonucu olarak sunulmaz.

Gitleaks sır taraması,85 bağımlılık checksum kontrolü, NuGet/OSV kontrolü,
Clang SAST ve managed analiz geçti. İncelenmiş iki upstream bilgi uyarısı dışında
yeni bulgu yok. Yeni yerel kişisel ayarların bozulması/uyumsuzluğu için reddetme
testleri eklendi. Web servisi olmadığından DAST/auth testleri uygulanmaz.

## 0.2.0 güncellemesi

Otomatik gürültü azaltma ve kategori menüsü eklendi. Native63 kontrol ve
managed27 kontrol geçer: ortam artışına güç tepkisi, konuşma/300ms son-ek
koruması, manuel moda dönüş, kapalı mod, güvenli sonlu değerler, eski profil
uyumluluğu ve gerçek C ABI2 parametre/ölçüm geçişi dahil. Yeni WPF smoke yedi
sayfanın ayarları koruduğunu, otomatik modda manuel kontrolün kapandığını,
TR/EN ve 640×480 düzenini kontrol eder. Görüntüler artifacts/ui altındadır.
Algoritma davranış testleri gerçek Türkçe konuşma kalitesi garantisi değildir.
VB-CABLE artık kurulu ve her iki endpoint Windows'ta doğrulandı; Discord/
Valorant uçtan uca aktarımı hâlâ kullanıcı teyidi ve canlı test bekliyor.
Aşağıdaki performans verileri 0.1.0 ölçümleridir; 0.2.0 için ölçüm yenilenmeden
aynı sonuç iddia edilmez.

0.2.0 otomatik modla 30.4sn USB mikrofon capture-only testi geçti: CPU ortalama
%0.197, tepe çalışma belleği121.43MiB, sıfır tampon hatası, son blok0.081ms.
Bu kısa ölçümde giriş sessizdi; konuşma kalite testi, sanal çıkış veya oyun
eşzamanlılığı değildir. Otomatik karışım alt sınır .35'teydi. RAM'deki2sn örnek
yalnızca doğrulandı; ses kaydı diske yazılmadı. artifacts/ui/live-result.json.
Gitleaks, bağımlılık kontrolü, managed analiz ve Clang SAST yeniden geçti;
önceden incelenmiş iki upstream bilgi uyarısı dışında bulgu yok.
AddressSanitizer DSP/resampler testleri yeniden geçti.

Bu dosya ölçülen sonuçları ve bekleyen testleri ayırır. Performans hedefi,
gerçek uçtan uca gecikme veya oyun FPS sonucu olarak gösterilmez.

| Ortam/cihaz | Durum |
|---|---|
| Windows11 Home x64,10.0.26300, Ryzen5 7600,32GB RAM | Yerel build/UI/capture doğrulandı |
| USB PnP Audio Device (kullanıcının Fifine T732'si) | WASAPI48kHz mono canlı capture/2sn RAM örneği doğrulandı |
| G435 / Iriun / Realtek / ekran çıkışları | Listeleniyor; işleme/dinleme test edilmedi |
| Windows10 x64 | Hedef; cihaz/işletim sistemi üzerinde çalıştırılmadı |
| VB-CABLE | 0.1.0 teslimatında yoktu; artık kurulu ve listeleniyor, canlı yönlendirme henüz doğrulanmadı |
| Daha düşük güçlü ikinci bilgisayar | Test edilmedi |

.NET10 desteği Windows sürümü/lifecycle'a bağlıdır; Microsoft'un
[uyumluluk tablosu](https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.md)
ayrıca geçerlidir. SES'in tablosu yalnızca kendi doğrulamasını gösterir.

## Otomatik testler

Native54 kontrol: mute/bypass limiter, clipping/NaN/sonsuzluk, sessizlikte AGC,
kompresör/HPF, RNNoise durağan gürültü, chirp ile960 örnek hizalama,
gürültü/gain geçişlerinde süreklilik,300 adversarial yasal filtre yapılandırması.
miniaudio ayrı test:44.1kHz stereo→48kHz mono ve48kHz mono→44.1kHz stereo.
Managed24 test: bağımsız4preset, güvenli JSON paylaşımı/import boyut/sürüm/NaN/
null/tekrarlanan alanlar, WAV/RMS eşitleme, kalibrasyon başarısı/clipping/yetersiz
konuşma, yerel durum kurtarma, gerçek C ABI/cihaz listeleme,960sample A/B
hizalama, geçersiz düzenlenen ayarları güvenli reddetme ve kayıp cihazda
başka mikrofona geçmeme.

Bir saatlik **sanal** saat farkı testi±600ppm'de360000 blok boyunca tampon
sınırlarını doğrular. Fiziksel cihazlarla bir saat canlı bağlantı testi değildir.
Türkçe sessiz kelimeler, fan/klavye/mouse altında dinleme ve preset ses kalitesi
otomatik tone/noise testiyle onaylanamaz; kullanıcının dinleme testi bekleniyor.

WPF smoke: gerçek render, TR/EN,4preset seçimi, mute/bypass, gelişmiş kontrol ve
1080×840/780×650/640×480 pencere görüntüleri. Per-monitor DPI manifest'i ve
ekran okuyucu etiketleri mevcut.100/150/200% gerçek ekran ölçekleri ve Narrator
ile kapsamlı test ayrıca bekliyor.

## Performans

İlk30.7sn gizli WPF+gerçek mikrofon capture testi: toplam CPU ortalaması%0.27,
tepe çalışma belleği152.7MiB, sıfır tampon hatası (capture-only), son480örnek DSP
blok süresi0.16ms. Çıktı: artifacts/ui/live-result.json. CPU tüm12 mantıksal
işlemciye göre normalize edilir. Sanal çıkış bağlı değildir; oyun eşzamanlılığı
ölçülmemiştir. Bellek ilk ölçümde150MB hedefinin biraz üstündedir.
60sn çevrimdışı tone~875ms'de işlenir; bir çekirdekte gerçek zaman oranı%1.46.
Bu toplam uygulama/oyun benchmark'ı değildir.

Son self-contained paket testi:30.6sn gizli UI+USB mikrofon, toplam CPU%0.219,
tepe çalışma belleği128.79MiB (yaklaşık135.0MB),1554720 işlenmiş örnek,
2sn/96000 RAM örneği, sıfır capture tampon hatası. Son DSP blok süresi0.251ms.
artifacts/package-final/live-result.json. Tampon belleği önceden ayrılır, yalnızca
yazılmış örnekler yayımlanır; kullanılmayan sayfaların başta sıfırlanması kaldırıldı.
Bu değişiklik sonrası CPU ve bellek hedefleri bu kısa capture-only koşulunda sağlandı.
Sanal çıkış/oyun dahil ölçüm veya uzun süre garantisi olarak yorumlanmamalıdır.

## Güvenlik ve teslimat

Gitleaks kaynak taraması: sıfır secret.85 vendored dosyanın SHA256 doğrulaması
geçti. NuGet vulnerability sorgusu: ek direct/transitive paket bulgusu yok.
OSV RNNoise commit sorgusu: bulgu yok. miniaudio0.11.25 için
**CVE-2026-32837** WAV BEXT decoder bulgusu geldi; SES `MA_NO_DECODING` ile
bu kodu derlemiyor. Preprocessed translation unit'te etkilenen fonksiyonların
olmadığı otomatik kontrol edildi. Audio dosyası içe aktarma yok; bu kullanımda
erişilebilir açık değildir. Gelecekte decoder eklenirse dependency yükselt.
Clang SAST: SES kodunda bulgu yok, miniaudio'da2 gereksiz ilk atama uyarısı
source context'te incelendi ve informational olarak raporlandı. Diğer uyarılar
security script'ini başarısız yapar. Managed analyzers: sıfır uyarı/hata.
AddressSanitizer native DSP+resampler testleri geçti. DAST/auth uygulanmaz;
bu uygulamada web servisi yoktur. Taramalar tüm olası açıkların kanıtı değildir.

Bağımsız reviewer960sample hizalama ve anahtar/gain geçiş kusurlarını buldu;
regresyonla düzeltildi ve yeniden incelendi. Kalan Important bulgu bildirilmedi.
Self-contained x64 publish ve gerçek WPF smoke doğrulandı. Paket dijital imzasız.
ZIP ayrı klasöre çıkarılıp Windows dizini çalışma diziniyle açılarak tekrar
smoke testinden geçti; engine DLL'i çalışma dizini/PATH üzerinden aranmadı.

Hedefler: toplam CPU≤%3, gizli UI bellek≤150MB, ek gecikme≤40ms.
RNNoise20ms algoritmik gecikmesi doğrulandı; UI tampon hesabına eklenir.
WASAPI/sanal sürücü dahil fiziksel uçtan uca gecikme **ölçülmedi**.
Discord+Valorant FPS/%1 düşük FPS/frametime ve ikinciPC karşılaştırması bekliyor.
Mikrofon dalgalanmasının donanımsal nedeni tespit edilmiş sayılmaz.

## 0.6.4 automatic soft expansion scope

Real-DLL offline comparison covered 17 deterministic synthetic fixtures.
Low-VAD isolated keyboard events improved about 26 dB in selected 200 ms
event windows; earlier high-VAD keyboard events did not improve. Desk
impacts remained essentially unchanged (less than 0.2 dB per event).
Voiced harmonic proxies were preserved, including soft short onsets. These
are not human recordings. Unvoiced/quiet Turkish onsets need listening
acceptance; full desk-impact rejection is unresolved. New behavior applies
only to automatic sensitivity with soft expansion and noise reduction on.
Manual sensitivity and gate behavior are unchanged. Long-run buffer and
resource acceptance from 0.6.3 remains unresolved, not reset by this change.

## 0.6.5 jitter reproduction and reserve correction

Baseline exact production FIFO reproduced 36 underruns per 600s with
-600ppm and independent bounded 0..3.5ms capture/render sine scheduling
delays. Delays apply to absolute nominal deadlines, not every period.
Reserve-only correction failed some 1440-frame callbacks. Packet-normalized
servo plus callback-aware post-render reserve is tested across callback
sizes120/441/480/960/1440, clocks-600/0/+600ppm, phases0/0.1/5/9.9ms,
zero/capture-only/both-sine/catch-up scheduling. Genuine source loss must
still report starvation and silence, never stale audio. Estimates exclude
device latency and scheduling spikes; they cannot prove the 40ms target.
The old estimate used remainingFill after render and therefore omitted
the delivered callback from queue duration. The corrected estimate uses
startingFill; it may exceed40ms. Stability fixes are not latency acceptance,
and actual physical-microphone to consumer latency remains unmeasured.
