# Guest-only acceptance runner. Never dot-source or execute this on the daily host.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Guid]$VmId,
    [ValidateSet('Diagnostics','CodeIntegrityVerifier','EnableHvciLab','Capture','RemoveReinstall','HibernatePrepare','HibernateVerify','Shutdown')]
    [string]$Mode='Diagnostics',
    [switch]$Extended,
    [ValidateRange(10,3600)][int]$DurationSeconds=60
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
# These read-only checks precede all filesystem writes, process launches and COM1.
$system=Get-CimInstance -ClassName Win32_ComputerSystem
$product=Get-CimInstance -ClassName Win32_ComputerSystemProduct
$hardwareId=[Guid]::Empty
if($VmId -eq [Guid]::Empty -or $system.Manufacturer -cne 'QEMU' -or
   $system.Model -cne 'VeyloDriverLab' -or $env:COMPUTERNAME -cne 'VEYLO-LAB' -or
   ![Guid]::TryParse([string]$product.UUID,[ref]$hardwareId) -or $hardwareId -ne $VmId){
    throw 'Guest identity rejected: this runner requires its exact isolated Veylo VM UUID.'
}
if(($Extended -or $PSBoundParameters.ContainsKey('DurationSeconds')) -and $Mode -cne 'Capture'){
    throw 'Capture options are valid only in Capture mode.'
}
if($PSBoundParameters.ContainsKey('DurationSeconds') -and !$Extended){throw 'DurationSeconds requires Extended.'}
$acceptanceRoot='C:\VeyloAcceptance'
$labRoot='C:\VeyloLab'
$outputNames=@('diagnostics.json','verifier.json','capture-result.json','capture.json','capture.log',
    'reinstall.json','remove.log','install.log','shutdown.json','failure.json','powercfg.log',
    'verifier-settings.log','verifier-query.log','verifier-enable.log','hvci-snapshot.json','hvci.json','hvci-bcd.log',
    'hvci-bcd-before.log','hvci-vsm.log','hibernate-snapshot.json','hibernate-prepare.json','hibernate.json',
    'hibernate-powercfg.log','hibernate-request.log','hibernate-capture.json','hibernate-capture.log')

function Assert-CanonicalPath([string]$Path,[string]$Within,[switch]$MayNotExist){
    $full=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetFullPath($Within).TrimEnd('\')
    if($full -ine $root -and !$full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){
        throw 'Path escapes its fixed guest directory.'
    }
    if(!$MayNotExist -and !(Test-Path -LiteralPath $full)){throw 'Required guest file is missing.'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -LiteralPath $cursor -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse paths are forbidden.'}
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if(!$parent -or $parent -eq $cursor){break};$cursor=$parent
    }
    return $full
}
function Read-BoundedJson([string]$Path,[string]$Within,[int]$Limit=65536){
    $full=Assert-CanonicalPath $Path $Within
    $file=Get-Item -LiteralPath $full -Force
    if($file.PSIsContainer -or $file.Length -lt 2 -or $file.Length -gt $Limit){throw 'Invalid JSON file size/type.'}
    return (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json)
}
function Assert-TrustedGuestAcl([string]$Path){
    $acl=Get-Acl -LiteralPath $Path
    $trusted=@('S-1-5-32-544','S-1-5-18')
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin $trusted){throw 'Guest payload must be owned by Administrators or SYSTEM.'}
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $rule.IdentityReference.Value -cnotin $trusted){throw 'Guest payload ACL must allow only Administrators and SYSTEM.'}
    }
    if((Get-Item -LiteralPath $Path).PSIsContainer -and !$acl.AreAccessRulesProtected){throw 'Guest payload root must have a protected ACL.'}
}
function Assert-Inventory($Manifest,[string[]]$Names,[string]$Root){
    Assert-TrustedGuestAcl $Root
    $entries=@($Manifest.files.PSObject.Properties)
    if($entries.Count -ne $Names.Count){throw 'Guest manifest inventory count differs.'}
    foreach($entry in $entries){
        if($entry.Name -cnotin $Names -or $entry.Value -isnot [string] -or
           $entry.Value -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid guest manifest entry.'}
        $path=Assert-CanonicalPath (Join-Path $Root $entry.Name) $Root
        Assert-TrustedGuestAcl $path
        $file=Get-Item -LiteralPath $path -Force
        if($file.PSIsContainer -or $file.Length -lt 1 -or $file.Length -gt 16MB -or
           (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){
            throw ('Guest payload checksum/type/size mismatch: '+$entry.Name)
        }
    }
}
# Pin the running script and updated executable independently of the original seed.
$manifest=Read-BoundedJson (Join-Path $acceptanceRoot 'acceptance-manifest.json') $acceptanceRoot
Assert-TrustedGuestAcl $acceptanceRoot
Assert-TrustedGuestAcl (Join-Path $acceptanceRoot 'acceptance-manifest.json')
$manifestId=[Guid]::Empty
if($manifest.schema -ne 1 -or $manifest.testOnly -isnot [bool] -or !$manifest.testOnly -or
   ![Guid]::TryParseExact([string]$manifest.vmId,'D',[ref]$manifestId) -or $manifestId -ne $VmId){
    throw 'Acceptance manifest identity rejected.'
}
Assert-Inventory $manifest @('driver-vm-acceptance.ps1','ses_driver_capture_lab_tests.exe') $acceptanceRoot
$ownPath=Assert-CanonicalPath $PSCommandPath $acceptanceRoot
if($ownPath -ine (Join-Path $acceptanceRoot 'driver-vm-acceptance.ps1')){throw 'Runner must execute from its fixed verified guest path.'}
$seed=Read-BoundedJson (Join-Path $labRoot 'veylo-lab-seed.json') $labRoot
Assert-TrustedGuestAcl $labRoot
Assert-TrustedGuestAcl (Join-Path $labRoot 'veylo-lab-seed.json')
$seedId=[Guid]::Empty
if($seed.schema -ne 1 -or $seed.testOnly -isnot [bool] -or !$seed.testOnly -or
   ![Guid]::TryParseExact([string]$seed.id,'D',[ref]$seedId) -or $seedId -ne $VmId){throw 'Original guest seed identity rejected.'}
$seedNames=@('SesMicrophone.inf','SesMicrophone.sys','SesMicrophone.cat','SYSVAD-LICENSE',
    'lab-test.cer','ses_driver_lab_tests.exe','ses_driver_capture_lab_tests.exe','DRIVER.md',
    'DRIVER-LAB.md','LICENSE','README-TEST-SIGNED.txt','test-signing-manifest.json','devcon.exe','guest.ps1')
Assert-Inventory $seed $seedNames $labRoot
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if($Mode -cne 'Diagnostics' -and !$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'This mode requires an already elevated guest token; no automatic elevation is performed.'
}

function Write-Serial([string]$Tag,$Value){
    $message=$Tag+': '+($Value | ConvertTo-Json -Depth 12 -Compress)
    try{
        $port=[IO.Ports.SerialPort]::new('COM1',115200)
        $port.WriteTimeout=1000;$port.Open()
        try{$port.WriteLine($message)}finally{$port.Close();$port.Dispose()}
    }catch{Write-Warning 'COM1 summary could not be delivered.'}
}
function Get-OutputPath([string]$Name){
    if($Name -cnotin $outputNames){throw 'Unapproved guest output filename.'}
    $path=Assert-CanonicalPath (Join-Path $acceptanceRoot $Name) $acceptanceRoot -MayNotExist
    if(Test-Path -LiteralPath $path){
        Assert-TrustedGuestAcl $path
        $file=Get-Item -LiteralPath $path -Force
        if($file.PSIsContainer -or $file.Length -gt 2MB){throw 'Invalid existing report path.'}
    }
    return $path
}
function Write-Report([string]$Name,$Value,[string]$Tag='VEYLO_ACCEPTANCE_RESULT'){
    $path=Get-OutputPath $Name
    [IO.File]::WriteAllText($path,($Value | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
    Write-Serial $Tag $Value
}
function New-Result([string]$Status){
    return [ordered]@{schema=1;vmId=$VmId.ToString('D');mode=$Mode;status=$Status;
        utc=[DateTime]::UtcNow.ToString('o');testOnly=$true;productionReady=$false}
}
# Child output is drained asynchronously, bounded to 1 MiB per invocation, and
# killed on a deadline or output flood. No shell or user supplied arguments.
function Stop-BoundedGuestChild($Process){
    if($Process.HasExited){return}
    try{$Process.Kill()}catch{
        # The child may exit between HasExited and Kill, especially after S4.
        # Only confirmed exit suppresses the race; a live-process error escapes.
        if(!$Process.HasExited){throw}
    }
}
function Invoke-BoundedTool([string]$Executable,[string[]]$Arguments,[string]$LogName,[int]$DeadlineSeconds,[switch]$CreateNewLog){
    $logPath=Get-OutputPath $LogName
    foreach($argument in $Arguments){if($argument.Contains('"') -or $argument.Contains("`r") -or $argument.Contains("`n")){throw 'Unsafe tool argument.'}}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable;$start.Arguments=($Arguments | ForEach-Object {'"'+$_+'"'}) -join ' '
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $logMode=if($CreateNewLog){[IO.FileMode]::CreateNew}else{[IO.FileMode]::Create}
    $writer=[IO.File]::Open($logPath,$logMode,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $watch=[Diagnostics.Stopwatch]::StartNew();$nextHeartbeat=0;$total=0;$timedOut=$false;$outputLimited=$false;$started=$false
    try{
        if(!$process.Start()){throw 'Guest child process did not start.'};$started=$true
        $streams=@($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)
        $buffers=@([byte[]]::new(4096),[byte[]]::new(4096))
        $pending=@($streams[0].ReadAsync($buffers[0],0,4096),$streams[1].ReadAsync($buffers[1],0,4096))
        $finished=@($false,$false)
        while(!$process.HasExited -or !$finished[0] -or !$finished[1]){
            for($index=0;$index -lt 2;$index++){
                if(!$finished[$index] -and $pending[$index].IsCompleted){
                    $count=$pending[$index].GetAwaiter().GetResult()
                    if($count -eq 0){$finished[$index]=$true;continue}
                    if($total+$count -gt 1MB){$outputLimited=$true;break}
                    $writer.Write($buffers[$index],0,$count);$total+=$count
                    $pending[$index]=$streams[$index].ReadAsync($buffers[$index],0,4096)
                }
            }
            if($outputLimited -or $watch.Elapsed.TotalSeconds -gt $DeadlineSeconds){
                $timedOut=!$outputLimited
                Stop-BoundedGuestChild $process
                break
            }
            if($watch.Elapsed.TotalSeconds -ge $nextHeartbeat){
                Write-Serial 'VEYLO_ACCEPTANCE_HEARTBEAT' @{vmId=$VmId.ToString('D');mode=$Mode;elapsedSeconds=[int]$watch.Elapsed.TotalSeconds}
                $nextHeartbeat=$watch.Elapsed.TotalSeconds+15
            }
            Start-Sleep -Milliseconds 50
        }
        if(!$process.WaitForExit(5000)){throw 'Child process did not terminate within its shutdown guard.'}
        return @{exitCode=$process.ExitCode;timedOut=$timedOut;outputLimited=$outputLimited;deadlineSeconds=$DeadlineSeconds;
            elapsedSeconds=[math]::Round($watch.Elapsed.TotalSeconds,2);log=$LogName;bytes=$total}
    }finally{
        try{
            if($started -and !$process.HasExited){Stop-BoundedGuestChild $process;$null=$process.WaitForExit(5000)}
        }finally{$writer.Dispose();$process.Dispose();$watch.Stop()}
    }
}
function Get-WindowsLicenseEvidence{
    # PartialProductKey exists only in the internal WMI filter, never in output.
    $rows=@(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL")
    return @($rows | ForEach-Object {[ordered]@{Name=[string]$_.Name;Description=[string]$_.Description;
        LicenseStatus=[int]$_.LicenseStatus;GracePeriodRemaining=[int]$_.GracePeriodRemaining}})
}
function Get-DeviceGuardEvidence{
    try{
        $guard=Get-CimInstance -Namespace root/Microsoft/Windows/DeviceGuard -ClassName Win32_DeviceGuard
        $status=[int]$guard.VirtualizationBasedSecurityStatus
        $configured=@($guard.SecurityServicesConfigured | ForEach-Object {[int]$_})
        $running=@($guard.SecurityServicesRunning | ForEach-Object {[int]$_})
        return @{query='Passed';VirtualizationBasedSecurityStatus=$status;SecurityServicesConfigured=$configured;
            SecurityServicesRunning=$running;hvci=($(if($status -eq 2 -and 2 -in $running){'Passed'}else{'Not run'}))}
    }catch{return @{query='Findings';hvci='Not run';error=$_.Exception.Message}}
}
function Get-BoundedEvents([string]$LogName,[Nullable[int]]$Id){
    $filter=@{LogName=$LogName;StartTime=(Get-Date).AddDays(-7)}
    if($null -ne $Id){$filter.Id=[int]$Id}else{$filter.Level=@(1,2)}
    try{
        return @((Get-WinEvent -FilterHashtable $filter -MaxEvents 32 -ErrorAction Stop) | ForEach-Object {
            $message=[string]$_.Message;if($message.Length -gt 512){$message=$message.Substring(0,512)}
            @{id=$_.Id;utc=$_.TimeCreated.ToUniversalTime().ToString('o');provider=$_.ProviderName;message=$message}
        })
    }catch{
        if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){return @()}
        throw
    }
}
function Get-SesDevices{
    return @(Get-CimInstance -ClassName Win32_PnPEntity | Where-Object {
        @($_.HardwareID) -icontains 'ROOT\SES_MICROPHONE'
    })
}
function Test-SesDeviceIdentity($Devices){
    $items=@($Devices)
    if($items.Count -ne 1 -or $null -eq $items[0]){return $false}
    $device=$items[0]
    foreach($property in @('Service','DeviceID','HardwareID')){
        if($null -eq $device.PSObject.Properties[$property]){return $false}
    }
    # DevCon's root audio enumerator uses ROOT\MEDIA\0000 as its instance ID.
    # The immutable hardware ID, not that instance prefix, identifies our driver.
    return ($device.Service -is [string] -and $device.Service -ieq 'SesMicrophone' -and
        $device.DeviceID -is [string] -and
        [regex]::IsMatch($device.DeviceID,'\AROOT\\(?:MEDIA|SES_MICROPHONE)\\[0-9]{4}\z',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant) -and
        @($device.HardwareID | Where-Object {$_ -is [string] -and $_ -ieq 'ROOT\SES_MICROPHONE'}).Count -eq 1)
}
function Assert-OneSesDevice{
    $devices=@(Get-SesDevices)
    if(!(Test-SesDeviceIdentity $devices)){
        throw 'Exactly one correctly identified ROOT\SES_MICROPHONE device is required.'
    }
    return $devices[0]
}
# Pure decisions are extracted by AST for host regression fixtures. They never
# invoke verifier, access the registry, or infer HVCI from Code Integrity flags.
function ConvertFrom-VerifierRegistryEvidence($Level,$Drivers,$LevelKind,$DriversKind,$ProtectionVerified){
    $evidence=@{source='protected guest registry';configured=$false;flags=$null;targets=@();hvciEvidence=$false}
    if($ProtectionVerified -isnot [bool] -or !$ProtectionVerified -or $LevelKind -cne 'DWord' -or
       $DriversKind -cne 'String' -or ($Level -isnot [int] -and $Level -isnot [uint32]) -or $Drivers -isnot [string]){
        $evidence.reason='Registry protection or value types were not verified.';return $evidence
    }
    $targets=@($Drivers.Trim() -split '\s+' | Where-Object {$_})
    $evidence.targets=$targets
    if($Level -ge 0){$evidence.flags=('0x{0:x8}' -f [uint32]$Level)}
    $evidence.configured=($Level -eq 0x021209bb -and $targets.Count -eq 1 -and $targets[0] -ieq 'SesMicrophone.sys')
    $evidence.reason=if($evidence.configured){'Exact requested mask and only the requested driver are saved; activation requires a boot.'}else{'Saved verifier mask or target inventory differs.'}
    return $evidence
}
function Get-VerifierEnableDecision($ExitCode,$TimedOut,$OutputLimited,$ConfiguredEvidence){
    $accepted=($ExitCode -is [int] -and $ExitCode -in @(0,2) -and $TimedOut -is [bool] -and !$TimedOut -and
        $OutputLimited -is [bool] -and !$OutputLimited -and $ConfiguredEvidence -is [Collections.IDictionary] -and
        $ConfiguredEvidence.Contains('configured') -and $ConfiguredEvidence.configured -is [bool] -and $ConfiguredEvidence.configured)
    return @{rebootRequired=$accepted;status=($(if($accepted){'Reboot required'}else{'Findings'}));activeVerified=$false;hvciEvidence=$false}
}
function ConvertFrom-VerifierActiveEvidence($Text,$ExitCode,$TimedOut,$OutputLimited){
    $evidence=@{source='bounded verifier /query';activeVerified=$false;flags=$null;targets=@();hvciEvidence=$false}
    if($Text -isnot [string] -or $Text.Length -gt 65536 -or $ExitCode -isnot [int] -or $ExitCode -ne 0 -or
       $TimedOut -isnot [bool] -or $TimedOut -or $OutputLimited -isnot [bool] -or $OutputLimited){
        $evidence.reason='Active verifier query failed, exceeded bounds, or has an unknown result.';return $evidence
    }
    $flags=[regex]::Matches($Text,'(?im)^\s*Verifier Flags:\s*(0x[0-9a-f]{8})\s*$')
    $modules=[regex]::Matches($Text,'(?im)^\s*MODULE:\s*(\S+)\s+\(load:\s*(\d{1,10})\s*/\s*unload:\s*(\d{1,10})\)\s*$')
    $moduleLines=[regex]::Matches($Text,'(?im)^\s*MODULE:')
    $evidence.targets=@($modules | ForEach-Object {$_.Groups[1].Value})
    if($flags.Count -eq 1){$evidence.flags=$flags[0].Groups[1].Value.ToLowerInvariant()}
    $evidence.activeVerified=($flags.Count -eq 1 -and $evidence.flags -ceq '0x021209bb' -and
        [regex]::Matches($Text,'(?im)^\s*Driver Verification List\s*$').Count -eq 1 -and
        $modules.Count -eq 1 -and $moduleLines.Count -eq 1 -and $evidence.targets[0] -ieq 'SesMicrophone.sys' -and
        [uint64]$modules[0].Groups[2].Value -gt [uint64]$modules[0].Groups[3].Value)
    $evidence.reason=if($evidence.activeVerified){'Exact requested flags and sole loaded target observed in active query.'}else{'Active query format, flags, loaded target, or driver inventory differs.'}
    return $evidence
}
function Get-SavedVerifierEvidence{
    $registryPath='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $key=$null
    try{
        $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        # WinPS 5.1 treats registry -LiteralPath as a filesystem path. This
        # provider-qualified constant contains no wildcard or user input.
        $acl=Get-Acl -Path $registryPath
        if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin $trusted){throw 'Verifier settings registry owner is untrusted.'}
        $writes=[Security.AccessControl.RegistryRights]::SetValue -bor [Security.AccessControl.RegistryRights]::CreateSubKey -bor
            [Security.AccessControl.RegistryRights]::Delete -bor [Security.AccessControl.RegistryRights]::ChangePermissions -bor [Security.AccessControl.RegistryRights]::TakeOwnership
        foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
            if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
               !($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
               ($rule.RegistryRights -band $writes) -and $rule.IdentityReference.Value -cnotin $trusted){throw 'Verifier settings registry has an untrusted writer.'}
        }
        $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management',$false)
        if(!$key){throw 'Verifier settings registry is unavailable.'}
        $level=$key.GetValue('VerifyDriverLevel');$drivers=$key.GetValue('VerifyDrivers')
        $levelKind=$key.GetValueKind('VerifyDriverLevel').ToString();$driversKind=$key.GetValueKind('VerifyDrivers').ToString()
        return (ConvertFrom-VerifierRegistryEvidence $level $drivers $levelKind $driversKind $true)
    }catch{return @{source='protected guest registry';configured=$false;flags=$null;targets=@();hvciEvidence=$false;reason=$_.Exception.Message}}
    finally{if($key){$key.Dispose()}}
}
function Get-ActiveVerifierEvidence($Process){
    $path=Get-OutputPath 'verifier-query.log'
    $file=Get-Item -LiteralPath $path -Force
    if($file.Length -gt 65536){return (ConvertFrom-VerifierActiveEvidence '' $Process.exitCode $Process.timedOut $true)}
    return (ConvertFrom-VerifierActiveEvidence ([IO.File]::ReadAllText($path)) $Process.exitCode $Process.timedOut $Process.outputLimited)
}
function Get-HvciLabDecision($Settings,$BcdExitCode,$TimedOut,$OutputLimited,$VsmExitCode,$VsmTimedOut,$VsmOutputLimited){
    $expected=@{EnableVirtualizationBasedSecurity=1;RequirePlatformSecurityFeatures=0;DeviceGuardLocked=0;HvciEnabled=1;HvciLocked=0}
    $verified=$true
    if($Settings -isnot [Collections.IDictionary]){return @{settingsPersisted=$false;rebootRequired=$false;status='Findings';activeVerified=$false;hvci='Not run';uefiLockRequested=$false}}
    foreach($name in $expected.Keys){
        $entry=$Settings[$name]
        if($null -eq $entry -or $entry.kind -cne 'DWord' -or $entry.value -isnot [int] -or $entry.value -ne $expected[$name]){$verified=$false}
    }
    $verified=$verified -and $BcdExitCode -is [int] -and $BcdExitCode -eq 0 -and
        $TimedOut -is [bool] -and !$TimedOut -and $OutputLimited -is [bool] -and !$OutputLimited -and
        $VsmExitCode -is [int] -and $VsmExitCode -eq 0 -and $VsmTimedOut -is [bool] -and !$VsmTimedOut -and
        $VsmOutputLimited -is [bool] -and !$VsmOutputLimited
    return @{settingsPersisted=$verified;rebootRequired=$verified;status=($(if($verified){'Reboot required'}else{'Findings'}));
        activeVerified=$false;hvci='Not run';uefiLockRequested=$false}
}
function Test-HvciBaselineFresh($SnapshotExists,$BeforeLogExists){
    return ($SnapshotExists -is [bool] -and !$SnapshotExists -and $BeforeLogExists -is [bool] -and !$BeforeLogExists)
}
function Test-HvciBeforeBcdEvidence($Text,$ExitCode,$TimedOut,$OutputLimited){
    return ($Text -is [string] -and $Text.Length -gt 0 -and $Text.Length -le 65536 -and
        $ExitCode -is [int] -and $ExitCode -eq 0 -and $TimedOut -is [bool] -and !$TimedOut -and
        $OutputLimited -is [bool] -and !$OutputLimited -and
        [regex]::Matches($Text,'(?im)^\s*identifier\s+\{current\}\s*$').Count -eq 1)
}
function Write-FirstHvciSnapshot($Snapshot){
    $path=Get-OutputPath 'hvci-snapshot.json'
    # CreateNew is the final atomic guard, even if another invocation raced
    # the earlier preflight. The prior snapshot is never truncated or replaced.
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{
        Assert-TrustedGuestAcl $path
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Snapshot | ConvertTo-Json -Depth 14))
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
    }finally{$stream.Dispose()}
    Write-Serial 'VEYLO_ACCEPTANCE_SNAPSHOT' $Snapshot
}
function Write-FirstHibernateSnapshot($Snapshot){
    $path=Get-OutputPath 'hibernate-snapshot.json'
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{
        Assert-TrustedGuestAcl $path
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Snapshot | ConvertTo-Json -Depth 14))
        if($bytes.Length -gt 65536){throw 'Hibernate baseline exceeds its bound.'}
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
    }finally{$stream.Dispose()}
    Write-Serial 'VEYLO_ACCEPTANCE_SNAPSHOT' $Snapshot
}
function Initialize-HibernateTokenReader{
    if('VeyloLab.HibernateTokenReader' -as [type]){return}
    # Called only from a guarded guest mode, never at module load. The fixed
    # TOKEN_STATISTICS ABI contains no pointers and is 56 bytes on x86/x64.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
namespace VeyloLab {
    public static class HibernateTokenReader {
        [StructLayout(LayoutKind.Explicit, Size = 56)]
        private struct TokenStatistics {
            [FieldOffset(8)] public uint AuthenticationLow;
            [FieldOffset(12)] public int AuthenticationHigh;
        }
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetTokenInformation(IntPtr token, int informationClass,
            out TokenStatistics statistics, uint informationLength, out uint returnLength);
        public static string ReadAuthenticationId(IntPtr token) {
            if (token == IntPtr.Zero || token == new IntPtr(-1))
                throw new ArgumentException("An existing identity token is required.");
            TokenStatistics statistics;
            uint returned;
            if (!GetTokenInformation(token, 10, out statistics, 56, out returned))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "TokenStatistics query failed.");
            if (returned != 56)
                throw new InvalidOperationException("Unexpected TokenStatistics ABI length.");
            return unchecked((uint)statistics.AuthenticationHigh).ToString("x8", CultureInfo.InvariantCulture)
                + statistics.AuthenticationLow.ToString("x8", CultureInfo.InvariantCulture);
        }
    }
}
'@
}
function Read-HibernateAuthenticationId($Identity){
    Initialize-HibernateTokenReader
    # Borrowed handle: WindowsIdentity owns it and stays alive until the caller's
    # finally. Never close, duplicate, modify or elevate this token.
    return [VeyloLab.HibernateTokenReader]::ReadAuthenticationId($Identity.Token)
}
function Test-HibernateInteractiveMembership($Principal){
    # IsInRole(SecurityIdentifier) tests enabled token membership, unlike
    # merely enumerating WindowsIdentity.Groups (which omits group attributes).
    foreach($sid in @('S-1-5-4','S-1-5-14')){
        if($Principal.IsInRole([Security.Principal.SecurityIdentifier]::new($sid))){return $true}
    }
    return $false
}
function Test-HibernateLogonSession($Session){
    return ($Session -is [Collections.IDictionary] -and $Session.userSid -is [string] -and
        $Session.userSid -cmatch '^S-1-(?:[0-9]+-)+[0-9]+$' -and
        $Session.userSid -cnotin @('S-1-5-18','S-1-5-19','S-1-5-20','S-1-5-7') -and
        $Session.authenticationId -is [string] -and $Session.authenticationId -cmatch '^[0-9a-f]{16}$' -and
        $Session.authenticationId -cnotin @('0000000000000000','00000000000003e4','00000000000003e5','00000000000003e6','00000000000003e7') -and
        $Session.interactive -is [bool] -and $Session.interactive -and
        $Session.sessionId -is [int] -and $Session.sessionId -ge 1)
}
function Get-HibernateSessionEvidence{
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{
        $tokenPrincipal=[Security.Principal.WindowsPrincipal]::new($identity)
        $session=@{userSid=$identity.User.Value;authenticationId=(Read-HibernateAuthenticationId $identity);
            interactive=(Test-HibernateInteractiveMembership $tokenPrincipal);sessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId}
        if(!(Test-HibernateLogonSession $session)){throw 'An original interactive user logon with a non-reserved authentication LUID is required.'}
        $guestOs=Get-CimInstance -ClassName Win32_OperatingSystem
        $session.bootUtc=$guestOs.LastBootUpTime.ToUniversalTime().ToString('o')
        return $session
    }finally{$identity.Dispose()}
}
# Parse invariant XML, never localized event messages. DTDs, duplicated fields,
# unbounded XML and unknown providers fail closed before decision making.
function ConvertFrom-HibernateEventXml($Text){
    if($Text -isnot [string] -or $Text.Length -lt 1 -or $Text.Length -gt 65536){throw 'Hibernate event XML size rejected.'}
    $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null;$settings.MaxCharactersInDocument=65536
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($Text),$settings)
    try{$document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader)}finally{$reader.Dispose()}
    $ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('e','http://schemas.microsoft.com/win/2004/08/events/event')
    $system=$document.SelectSingleNode('/e:Event/e:System',$ns)
    if(!$system){throw 'Hibernate event system metadata missing.'}
    $provider=$system.SelectSingleNode('e:Provider',$ns).GetAttribute('Name')
    if($provider -cnotin @('Microsoft-Windows-Kernel-Power','Microsoft-Windows-Power-Troubleshooter',
        'Microsoft-Windows-Kernel-General','Microsoft-Windows-WER-SystemErrorReporting','Microsoft-Windows-Eventlog')){throw 'Hibernate event provider rejected.'}
    $id=0;$record=[long]0;$utc=[DateTimeOffset]::MinValue
    if(![int]::TryParse($system.SelectSingleNode('e:EventID',$ns).InnerText,[ref]$id) -or $id -lt 1 -or
       ![long]::TryParse($system.SelectSingleNode('e:EventRecordID',$ns).InnerText,[ref]$record) -or $record -lt 1 -or
       ![DateTimeOffset]::TryParseExact($system.SelectSingleNode('e:TimeCreated',$ns).GetAttribute('SystemTime'),
           'yyyy-MM-ddTHH:mm:ss.FFFFFFFK',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$utc)){
        throw 'Hibernate event metadata rejected.'
    }
    $data=@{};$nodes=@($document.SelectNodes('/e:Event/e:EventData/e:Data',$ns))
    if($nodes.Count -gt 64){throw 'Hibernate event field count rejected.'}
    foreach($node in $nodes){
        $name=$node.GetAttribute('Name')
        if(!$name -or $name.Length -gt 64 -or $data.ContainsKey($name) -or $node.InnerText.Length -gt 2048){throw 'Hibernate event field rejected.'}
        $data[$name]=$node.InnerText
    }
    return @{provider=$provider;id=$id;recordId=$record;utc=$utc.ToUniversalTime().ToString('o');data=$data}
}
function Get-HibernateEvents($Snapshot){
    $prepared=[DateTimeOffset]::ParseExact([string]$Snapshot.utc,'o',[Globalization.CultureInfo]::InvariantCulture)
    # At most 128 relevant records. Hitting the cap means evidence is incomplete.
    $filter=@{LogName='System';StartTime=$prepared.UtcDateTime;Id=@(1,12,41,42,107,1001,104);
        ProviderName=@('Microsoft-Windows-Kernel-Power','Microsoft-Windows-Power-Troubleshooter',
            'Microsoft-Windows-Kernel-General','Microsoft-Windows-WER-SystemErrorReporting','Microsoft-Windows-Eventlog')}
    try{$events=@(Get-WinEvent -FilterHashtable $filter -MaxEvents 128 -ErrorAction Stop)}catch{
        if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){return @()};throw
    }
    if($events.Count -ge 128){throw 'Hibernate event inventory exceeded its bound.'}
    return @($events | ForEach-Object {ConvertFrom-HibernateEventXml $_.ToXml()})
}
function Get-HibernateResumeDecision($Snapshot,$Session,$Events,[string]$ExpectedVmId,[string]$NowUtc){
    $decision=@{status='Findings';resumeVerified=$false;reason='Missing or invalid hibernate evidence.'}
    try{
        $prepared=[DateTimeOffset]::ParseExact([string]$Snapshot.utc,'o',[Globalization.CultureInfo]::InvariantCulture)
        $now=[DateTimeOffset]::ParseExact($NowUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
        if($Snapshot.schema -ne 1 -or $Snapshot.mode -cne 'HibernatePrepare' -or $Snapshot.status -cne 'Snapshot' -or
           $Snapshot.testOnly -isnot [bool] -or !$Snapshot.testOnly -or $Snapshot.vmId -cne $ExpectedVmId -or
           $Snapshot.eventRecordId -isnot [long] -and $Snapshot.eventRecordId -isnot [int] -or $Snapshot.eventRecordId -lt 1 -or
           $now -le $prepared -or ($now-$prepared).TotalHours -gt 24){return $decision}
        if(!(Test-HibernateLogonSession $Snapshot.session) -or !(Test-HibernateLogonSession $Session)){return $decision}
        foreach($field in @('bootUtc','userSid','authenticationId','interactive','sessionId')){
            if($Snapshot.session[$field] -cne $Session[$field]){$decision.reason='Cold boot or guest logon/session continuity mismatch.';return $decision}
        }
        $boot=[DateTimeOffset]::ParseExact([string]$Session.bootUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
        if($boot -gt $prepared){return $decision}
        $inventory=@($Events)
        if($inventory.Count -lt 2 -or $inventory.Count -ge 128){return $decision}
        $seen=@{};$sleep=@();$wake=@()
        foreach($event in $inventory){
            $time=[DateTimeOffset]::ParseExact([string]$event.utc,'o',[Globalization.CultureInfo]::InvariantCulture)
            if($event.recordId -le $Snapshot.eventRecordId -or $seen.ContainsKey([string]$event.recordId) -or
               $time -lt $prepared -or $time -gt $now){return $decision};$seen[[string]$event.recordId]=$true
            if(($event.provider -ceq 'Microsoft-Windows-Kernel-General' -and $event.id -eq 12) -or
               ($event.provider -ceq 'Microsoft-Windows-Kernel-Power' -and $event.id -eq 41) -or
               ($event.provider -ceq 'Microsoft-Windows-WER-SystemErrorReporting' -and $event.id -eq 1001) -or
               ($event.provider -ceq 'Microsoft-Windows-Eventlog' -and $event.id -eq 104)){
                $decision.reason='Cold boot, unexpected shutdown, bugcheck or cleared system log after preparation.';return $decision
            }
            if($event.provider -ceq 'Microsoft-Windows-Kernel-Power' -and $event.id -eq 42){$sleep+=,$event}
            if($event.provider -ceq 'Microsoft-Windows-Power-Troubleshooter' -and $event.id -eq 1){$wake+=,$event}
        }
        if($sleep.Count -ne 1 -or $wake.Count -ne 1){$decision.reason='Exactly one paired sleep and wake cycle is required.';return $decision}
        foreach($event in @($sleep[0],$wake[0])){
            if($event.data.TargetState -cne '5' -or $event.data.EffectiveState -cne '5'){$decision.reason='S4 hibernation was not confirmed by both Windows events.';return $decision}
        }
        $sleepTime=[DateTimeOffset]::ParseExact([string]$wake[0].data.SleepTime,'yyyy-MM-ddTHH:mm:ss.FFFFFFFK',[Globalization.CultureInfo]::InvariantCulture)
        $wakeTime=[DateTimeOffset]::ParseExact([string]$wake[0].data.WakeTime,'yyyy-MM-ddTHH:mm:ss.FFFFFFFK',[Globalization.CultureInfo]::InvariantCulture)
        $entryTime=[DateTimeOffset]::ParseExact([string]$sleep[0].utc,'o',[Globalization.CultureInfo]::InvariantCulture)
        $resumeTime=[DateTimeOffset]::ParseExact([string]$wake[0].utc,'o',[Globalization.CultureInfo]::InvariantCulture)
        if($sleep[0].recordId -ge $wake[0].recordId -or $sleepTime -lt $prepared -or $wakeTime -le $sleepTime -or
           $wakeTime -gt $now -or [math]::Abs(($entryTime-$sleepTime).TotalSeconds) -gt 30 -or
           $resumeTime -lt $wakeTime -or ($resumeTime-$wakeTime).TotalSeconds -gt 120){return $decision}
        $decision.status='Passed';$decision.resumeVerified=$true;$decision.reason='Paired S4 events and original boot/logon session verified.'
        $decision.sleepRecordId=$sleep[0].recordId;$decision.wakeRecordId=$wake[0].recordId
        $decision.sleepUtc=$sleepTime.ToUniversalTime().ToString('o');$decision.wakeUtc=$wakeTime.ToUniversalTime().ToString('o')
    }catch{$decision.reason='Missing, malformed or unsupported Windows resume evidence.'}
    return $decision
}
function Assert-ProtectedRegistryPath([string]$Path){
    $prefix='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control'
    if($Path -cnotin @($prefix,($prefix+'\DeviceGuard'),($prefix+'\DeviceGuard\Scenarios'),
       ($prefix+'\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'))){throw 'Unapproved guest HVCI registry path.'}
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    # The exact whitelist above excludes wildcards and arbitrary caller paths.
    # Registry ACL reads require -Path on Windows PowerShell 5.1.
    $acl=Get-Acl -Path $Path
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin $trusted){throw 'HVCI registry owner is untrusted.'}
    $writes=[Security.AccessControl.RegistryRights]::SetValue -bor [Security.AccessControl.RegistryRights]::CreateSubKey -bor
        [Security.AccessControl.RegistryRights]::Delete -bor [Security.AccessControl.RegistryRights]::ChangePermissions -bor [Security.AccessControl.RegistryRights]::TakeOwnership
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
           !($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
           ($rule.RegistryRights -band $writes) -and $rule.IdentityReference.Value -cnotin $trusted){throw 'HVCI registry has an untrusted writer.'}
    }
}
function Read-HvciLabSettings{
    $prefix='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard'
    $settings=[ordered]@{}
    foreach($entry in @(
        @{label='EnableVirtualizationBasedSecurity';path=$prefix;name='EnableVirtualizationBasedSecurity'},
        @{label='RequirePlatformSecurityFeatures';path=$prefix;name='RequirePlatformSecurityFeatures'},
        @{label='DeviceGuardLocked';path=$prefix;name='Locked'},
        @{label='HvciEnabled';path=($prefix+'\Scenarios\HypervisorEnforcedCodeIntegrity');name='Enabled'},
        @{label='HvciLocked';path=($prefix+'\Scenarios\HypervisorEnforcedCodeIntegrity');name='Locked'},
        @{label='HvciMandatory';path=($prefix+'\Scenarios\HypervisorEnforcedCodeIntegrity');name='Mandatory'}
    )){
        $record=@{path=$entry.path;name=$entry.name;present=$false;kind=$null;value=$null}
        if(Test-Path -LiteralPath $entry.path){
            Assert-ProtectedRegistryPath $entry.path
            $key=Get-Item -LiteralPath $entry.path
            try{
                if($entry.name -in $key.GetValueNames()){
                    $record.present=$true;$record.kind=$key.GetValueKind($entry.name).ToString();$record.value=$key.GetValue($entry.name)
                }
            }finally{$key.Dispose()}
        }
        $settings[$entry.label]=$record
    }
    return $settings
}
$os=Get-CimInstance -ClassName Win32_OperatingSystem
$system32=Assert-CanonicalPath ([string]$os.SystemDirectory) ([string]$os.WindowsDirectory)
if([IO.Path]::GetFileName($system32) -ine 'System32'){throw 'Unexpected OS system directory.'}
try{
    switch($Mode){
        'Diagnostics' {
            $result=New-Result 'Passed'
            $result.licensing=@(Get-WindowsLicenseEvidence)
            $result.deviceGuard=Get-DeviceGuardEvidence
            $result.cpu=@(Get-CimInstance -ClassName Win32_Processor | Select-Object Name,
                VirtualizationFirmwareEnabled,VMMonitorModeExtensions,SecondLevelAddressTranslationExtensions)
            $result.powercfg=Invoke-BoundedTool (Join-Path $system32 'powercfg.exe') @('/a') 'powercfg.log' 30
            $result.verifierSettings=Invoke-BoundedTool (Join-Path $system32 'verifier.exe') @('/querysettings') 'verifier-settings.log' 30
            $result.verifierRunning=Invoke-BoundedTool (Join-Path $system32 'verifier.exe') @('/query') 'verifier-query.log' 30
            $result.verifierConfiguredEvidence=Get-SavedVerifierEvidence
            $result.verifierActiveEvidence=Get-ActiveVerifierEvidence $result.verifierRunning
            $result.systemBugchecks=@(Get-BoundedEvents 'System' ([Nullable[int]]1001))
            $result.codeIntegrityErrors=@(Get-BoundedEvents 'Microsoft-Windows-CodeIntegrity/Operational' $null)
            $result.syntheticAudioOnly=$true
            if($result.deviceGuard.query -ne 'Passed' -or @($result.licensing).Count -eq 0 -or
               $result.powercfg.exitCode -ne 0 -or $result.powercfg.timedOut -or $result.powercfg.outputLimited -or
               $result.verifierSettings.timedOut -or $result.verifierSettings.outputLimited -or
               $result.verifierRunning.timedOut -or $result.verifierRunning.outputLimited){$result.status='Findings'}
            Write-Report 'diagnostics.json' $result
        }
        'CodeIntegrityVerifier' {
            $result=New-Result 'Findings';$result.deviceGuard=Get-DeviceGuardEvidence
            # Code Integrity bit plus Microsoft's standard checks, target only this driver.
            $result.flags='0x021209bb';$result.target='SesMicrophone.sys'
            $result.enable=Invoke-BoundedTool (Join-Path $system32 'verifier.exe') @('/flags','0x021209bb','/driver','SesMicrophone.sys') 'verifier-enable.log' 30
            $result.verifierSettings=Invoke-BoundedTool (Join-Path $system32 'verifier.exe') @('/querysettings') 'verifier-settings.log' 30
            $result.verifierRunning=Invoke-BoundedTool (Join-Path $system32 'verifier.exe') @('/query') 'verifier-query.log' 30
            $result.verifierConfiguredEvidence=Get-SavedVerifierEvidence
            $result.verifierActiveEvidence=Get-ActiveVerifierEvidence $result.verifierRunning
            $result.enableDecision=Get-VerifierEnableDecision $result.enable.exitCode $result.enable.timedOut $result.enable.outputLimited $result.verifierConfiguredEvidence
            $result.rebootRequired=$result.enableDecision.rebootRequired;$result.status=$result.enableDecision.status
            Write-Report 'verifier.json' $result
        }
        'EnableHvciLab' {
            $snapshotPath=Get-OutputPath 'hvci-snapshot.json';$beforeLogPath=Get-OutputPath 'hvci-bcd-before.log'
            if(!(Test-HvciBaselineFresh (Test-Path -LiteralPath $snapshotPath) (Test-Path -LiteralPath $beforeLogPath))){
                throw 'Preserving the first HVCI baseline: snapshot or original BCD log already exists. Inspect and restore manually before considering another attempt.'
            }
            $result=New-Result 'Findings';$result.deviceGuardBefore=Get-DeviceGuardEvidence
            $before=Read-HvciLabSettings
            $snapshot=New-Result 'Snapshot';$snapshot.settingsBefore=$before;$snapshot.deviceGuardBefore=$result.deviceGuardBefore
            # CreateNew also makes the original BCD log an exclusive first-use
            # marker. A concurrent invocation cannot launch its enum or alter it.
            $result.bcdBefore=Invoke-BoundedTool (Join-Path $system32 'bcdedit.exe') @('/enum','{current}') 'hvci-bcd-before.log' 30 -CreateNewLog
            Assert-TrustedGuestAcl $beforeLogPath
            $beforeLog=Get-Item -LiteralPath $beforeLogPath
            if($beforeLog.Length -gt 65536){throw 'Original BCD export exceeded the 64 KiB bound; guest settings were not changed.'}
            $bcdBeforeText=[IO.File]::ReadAllText($beforeLogPath)
            if(!(Test-HvciBeforeBcdEvidence $bcdBeforeText $result.bcdBefore.exitCode $result.bcdBefore.timedOut $result.bcdBefore.outputLimited)){
                throw 'Original current-loader BCD evidence was not verified; guest settings were not changed.'
            }
            $snapshot.bcdBeforeProcess=$result.bcdBefore;$snapshot.bcdBeforeText=$bcdBeforeText
            $snapshot.restoreGuidance='After separate manual guest inspection, restore only the five values changed by this mode: EnableVirtualizationBasedSecurity, RequirePlatformSecurityFeatures, DeviceGuard Locked, HVCI Enabled and HVCI Locked. Use each saved kind/value if originally present; remove only an override this mode created for an originally absent value. Preserve Mandatory. Restore hypervisorlaunchtype and vsmlaunchtype from the saved current-loader BCD export; if an element was absent, remove this mode override. This runner never replaces the first baseline or automatically restores settings.'
            Write-FirstHvciSnapshot $snapshot
            $result.snapshot='hvci-snapshot.json'
            foreach($label in @('DeviceGuardLocked','HvciLocked','HvciMandatory')){
                if($before[$label].present -and ($before[$label].kind -cne 'DWord' -or $before[$label].value -ne 0)){
                    throw 'Existing locked, mandatory or unknown HVCI policy requires separate guest inspection.'
                }
            }
            $prefix='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control'
            Assert-ProtectedRegistryPath $prefix
            foreach($path in @(($prefix+'\DeviceGuard'),($prefix+'\DeviceGuard\Scenarios'),($prefix+'\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'))){
                if(!(Test-Path -LiteralPath $path)){New-Item -Path $path | Out-Null}
                Assert-ProtectedRegistryPath $path
            }
            $guardPath=$prefix+'\DeviceGuard';$hvciPath=$guardPath+'\Scenarios\HypervisorEnforcedCodeIntegrity'
            foreach($setting in @(
                @{path=$guardPath;name='EnableVirtualizationBasedSecurity';value=1},
                @{path=$guardPath;name='RequirePlatformSecurityFeatures';value=0},
                @{path=$guardPath;name='Locked';value=0},
                @{path=$hvciPath;name='Enabled';value=1},
                @{path=$hvciPath;name='Locked';value=0}
            )){
                Assert-ProtectedRegistryPath $setting.path
                New-ItemProperty -LiteralPath $setting.path -Name $setting.name -PropertyType DWord -Value $setting.value -Force | Out-Null
            }
            $result.bcd=Invoke-BoundedTool (Join-Path $system32 'bcdedit.exe') @('/set','hypervisorlaunchtype','auto') 'hvci-bcd.log' 30
            $result.vsm=Invoke-BoundedTool (Join-Path $system32 'bcdedit.exe') @('/set','vsmlaunchtype','auto') 'hvci-vsm.log' 30
            $result.settingsAfter=Read-HvciLabSettings
            $result.configureDecision=Get-HvciLabDecision $result.settingsAfter $result.bcd.exitCode $result.bcd.timedOut $result.bcd.outputLimited $result.vsm.exitCode $result.vsm.timedOut $result.vsm.outputLimited
            $result.rebootRequired=$result.configureDecision.rebootRequired;$result.status=$result.configureDecision.status
            $result.hvci='Not run';$result.activeVerified=$false
            Write-Report 'hvci.json' $result
        }
        'Capture' {
            $result=New-Result 'Findings';$result.syntheticAudioOnly=$true
            $result.licensing=@(Get-WindowsLicenseEvidence);$result.deviceGuard=Get-DeviceGuardEvidence
            $result.verifierRunning=Invoke-BoundedTool (Join-Path $system32 'verifier.exe') @('/query') 'verifier-query.log' 30
            $result.verifierConfiguredEvidence=Get-SavedVerifierEvidence
            $result.verifierActiveEvidence=Get-ActiveVerifierEvidence $result.verifierRunning
            if($Extended -and $DurationSeconds -eq 3600){
                $valid=@($result.licensing | Where-Object {
                    $_.LicenseStatus -eq 1 -and ($_.Description -notmatch '(?i)(timebased_eval|evaluation)' -or
                    ($_.GracePeriodRemaining -ge [math]::Ceiling(($DurationSeconds+180)/60) -and $_.GracePeriodRemaining -le 129600))
                })
                if($valid.Count -eq 0){throw 'One-hour capture requires activated Windows or a currently activated, unexpired 90-day evaluation. No activation, clock or grace bypass is attempted.'}
            }
            $jsonPath=Get-OutputPath 'capture.json'
            Assert-Inventory $manifest @('driver-vm-acceptance.ps1','ses_driver_capture_lab_tests.exe') $acceptanceRoot
            if(Test-Path -LiteralPath $jsonPath){Remove-Item -LiteralPath $jsonPath}
            $arguments=@('--isolated-lab','--json-report',$jsonPath)
            if($Extended){$arguments+=@('--extended','--duration-seconds',[string]$DurationSeconds)}
            $deadline=180;if($Extended){$deadline+=$DurationSeconds}
            $result.process=Invoke-BoundedTool (Join-Path $acceptanceRoot 'ses_driver_capture_lab_tests.exe') $arguments 'capture.log' $deadline
            try{
                if(!(Test-Path -LiteralPath $jsonPath)){throw 'Capture executable did not produce its required JSON report.'}
                $result.capture=Read-BoundedJson $jsonPath $acceptanceRoot 1MB
            }catch{
                $result.captureJsonError=$_.Exception.Message
                Write-Report 'capture-result.json' $result
                break
            }
            $evidence=$result.capture
            $passed=($result.process.exitCode -eq 0 -and !$result.process.timedOut -and !$result.process.outputLimited -and
                $evidence.schema -eq 1 -and $evidence.checks -gt 0 -and $evidence.failures -eq 0 -and $evidence.unsupported -eq 0 -and
                $evidence.verified_endpoints -eq 1 -and $evidence.formats_passed -eq 2 -and $evidence.self_tests -eq 0)
            if($Extended){
                $extendedEvidence=$evidence.extended_kernel_capture
                $passed=$passed -and $extendedEvidence.requested -eq $true -and $extendedEvidence.ran -eq $true -and
                    $extendedEvidence.requested_seconds -eq $DurationSeconds -and $extendedEvidence.elapsed_ms -ge $DurationSeconds*1000 -and
                    $extendedEvidence.elapsed_ms -le ($DurationSeconds*1000+1000)
            }
            $result.status=if($passed){'Passed'}else{'Findings'}
            Write-Report 'capture-result.json' $result
        }
        'RemoveReinstall' {
            $result=New-Result 'Findings';$result.scope='same-version remove/reinstall; upgrade and rollback not tested'
            $device=Assert-OneSesDevice;$result.before=@{instanceId=$device.DeviceID;service=$device.Service}
            Assert-Inventory $seed $seedNames $labRoot
            $devcon=Join-Path $labRoot 'devcon.exe'
            $result.remove=Invoke-BoundedTool $devcon @('remove',('@'+$device.DeviceID)) 'remove.log' 60
            if($result.remove.exitCode -eq 1){$result.status='Reboot required';$result.rebootRequired=$true;Write-Report 'reinstall.json' $result;break}
            if($result.remove.exitCode -ne 0 -or $result.remove.timedOut -or $result.remove.outputLimited){throw 'Exact-instance guest device removal failed.'}
            for($attempt=0;$attempt -lt 20 -and @(Get-SesDevices).Count -ne 0;$attempt++){Start-Sleep -Milliseconds 500}
            if(@(Get-SesDevices).Count -ne 0){throw 'Device absence was not confirmed; refusing a duplicate install.'}
            $result.absenceConfirmed=$true
            Assert-Inventory $seed $seedNames $labRoot
            $result.install=Invoke-BoundedTool $devcon @('install',(Join-Path $labRoot 'SesMicrophone.inf'),'ROOT\SES_MICROPHONE') 'install.log' 60
            if($result.install.exitCode -eq 1){$result.status='Reboot required';$result.rebootRequired=$true;Write-Report 'reinstall.json' $result;break}
            if($result.install.exitCode -ne 0 -or $result.install.timedOut -or $result.install.outputLimited){throw 'Verified guest INF reinstall failed.'}
            Start-Sleep -Seconds 5;$device=Assert-OneSesDevice
            $result.after=@{instanceId=$device.DeviceID;service=$device.Service;configManagerErrorCode=$device.ConfigManagerErrorCode}
            $result.status=if($device.ConfigManagerErrorCode -eq 0){'Passed'}else{'Findings'}
            Write-Report 'reinstall.json' $result
        }
        'HibernatePrepare' {
            $snapshotPath=Get-OutputPath 'hibernate-snapshot.json';$powerLog=Get-OutputPath 'hibernate-powercfg.log'
            if((Test-Path -LiteralPath $snapshotPath) -or (Test-Path -LiteralPath $powerLog)){
                throw 'Preserving the first hibernate baseline: do not retry preparation or replace its original evidence.'
            }
            $result=New-Result 'Findings';$result.resumeVerified=$false
            $device=Assert-OneSesDevice
            if($device.ConfigManagerErrorCode -ne 0){throw 'Guest microphone must be healthy before hibernation.'}
            $session=Get-HibernateSessionEvidence
            $result.powercfg=Invoke-BoundedTool (Join-Path $system32 'powercfg.exe') @('/a') 'hibernate-powercfg.log' 30 -CreateNewLog
            if($result.powercfg.exitCode -ne 0 -or $result.powercfg.timedOut -or $result.powercfg.outputLimited){throw 'Guest power capability query failed.'}
            Assert-TrustedGuestAcl $powerLog
            $latest=Get-WinEvent -LogName 'System' -MaxEvents 1 -ErrorAction Stop
            $snapshot=New-Result 'Snapshot';$snapshot.session=$session;$snapshot.eventRecordId=[long]$latest.RecordId
            $snapshot.device=@{instanceId=$device.DeviceID;service=$device.Service};$snapshot.powercfgBefore=$result.powercfg
            $snapshot.powercfgSha256=(Get-FileHash -LiteralPath $powerLog -Algorithm SHA256).Hash.ToLowerInvariant()
            $snapshot.restoreGuidance='No power policy is changed by this mode. Preserve this first baseline. Resume the same owned disk, then run HibernateVerify in the original interactive guest logon. A cold boot, new logon or absent paired S4 event evidence cannot pass.'
            Write-FirstHibernateSnapshot $snapshot
            # Prepared is never acceptance. If /h returns without real S4, the
            # second mode still requires Windows event and session continuity.
            $result.status='Prepared';$result.snapshot='hibernate-snapshot.json'
            Write-Report 'hibernate-prepare.json' $result
            Assert-Inventory $manifest @('driver-vm-acceptance.ps1','ses_driver_capture_lab_tests.exe') $acceptanceRoot
            Assert-Inventory $seed $seedNames $labRoot
            $result.request=Invoke-BoundedTool (Join-Path $system32 'shutdown.exe') @('/h') 'hibernate-request.log' 60
            $result.status=if($result.request.exitCode -eq 0 -and !$result.request.timedOut -and !$result.request.outputLimited){'Requested'}else{'Findings'}
            Write-Report 'hibernate-prepare.json' $result
        }
        'HibernateVerify' {
            $result=New-Result 'Findings';$result.syntheticAudioOnly=$true;$result.resumeVerified=$false
            # Invalidate a previous success before any attempt-specific read.
            # Write-Report still validates the fixed report path and its ACL.
            Write-Report 'hibernate.json' $result
            $snapshotPath=Get-OutputPath 'hibernate-snapshot.json';Assert-TrustedGuestAcl $snapshotPath
            $snapshot=Read-BoundedJson $snapshotPath $acceptanceRoot
            # Convert this nested JSON object to the same dictionary shape as
            # the current session; WinPS 5.1 does not have -AsHashtable.
            $savedSession=@{};foreach($property in $snapshot.session.PSObject.Properties){$savedSession[$property.Name]=$property.Value}
            $baseline=@{schema=$snapshot.schema;vmId=$snapshot.vmId;mode=$snapshot.mode;status=$snapshot.status;
                testOnly=$snapshot.testOnly;utc=$snapshot.utc;eventRecordId=$snapshot.eventRecordId;session=$savedSession}
            $powerLog=Get-OutputPath 'hibernate-powercfg.log';Assert-TrustedGuestAcl $powerLog
            if($snapshot.powercfgSha256 -cnotmatch '^[0-9a-f]{64}$' -or
               (Get-FileHash -LiteralPath $powerLog -Algorithm SHA256).Hash.ToLowerInvariant() -cne $snapshot.powercfgSha256){throw 'Original hibernate capability evidence changed.'}
            $result.session=Get-HibernateSessionEvidence
            $result.events=@(Get-HibernateEvents $snapshot)
            $result.resume=Get-HibernateResumeDecision $baseline $result.session $result.events $VmId.ToString('D') ([DateTime]::UtcNow.ToString('o'))
            $result.resumeVerified=$result.resume.resumeVerified
            if(!$result.resumeVerified){Write-Report 'hibernate.json' $result;break}
            $device=Assert-OneSesDevice
            if($device.ConfigManagerErrorCode -ne 0 -or $device.DeviceID -cne $snapshot.device.instanceId -or
               $device.Service -cne $snapshot.device.service){throw 'Original microphone device was not healthy after S4 resume.'}
            $jsonPath=Get-OutputPath 'hibernate-capture.json'
            if(Test-Path -LiteralPath $jsonPath){Remove-Item -LiteralPath $jsonPath}
            Assert-Inventory $manifest @('driver-vm-acceptance.ps1','ses_driver_capture_lab_tests.exe') $acceptanceRoot
            $result.process=Invoke-BoundedTool (Join-Path $acceptanceRoot 'ses_driver_capture_lab_tests.exe') @('--isolated-lab','--json-report',$jsonPath) 'hibernate-capture.log' 180
            Assert-TrustedGuestAcl $jsonPath
            $result.capture=Read-BoundedJson $jsonPath $acceptanceRoot 1MB
            $capture=$result.capture
            if($result.process.exitCode -eq 0 -and !$result.process.timedOut -and !$result.process.outputLimited -and
               $capture.schema -eq 1 -and $capture.checks -gt 0 -and $capture.failures -eq 0 -and $capture.unsupported -eq 0 -and
               $capture.verified_endpoints -eq 1 -and $capture.formats_passed -eq 2 -and $capture.self_tests -eq 0){$result.status='Passed'}
            Write-Report 'hibernate.json' $result
        }
        'Shutdown' {
            $result=New-Result 'Requested';$result.shutdownConfirmed=$false
            Write-Report 'shutdown.json' $result
            Stop-Computer -Force
        }
    }
}catch{
    $failure=New-Result 'Findings';$failure.error=$_.Exception.Message
    if(Get-Variable -Name result -ErrorAction SilentlyContinue){$failure.partialResult=$result}
    Write-Report 'failure.json' $failure
    throw
}
