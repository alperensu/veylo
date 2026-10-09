# Guest-only historical version transition. Never execute/dot-source on the daily host.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Guid]$VmId,
    [ValidateSet('Run','RollbackNative')][string]$Operation='Run',
    [Guid]$RunId=[Guid]::Empty
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
# The entire host rejection is read-only and precedes writes, native imports and processes.
$system=Get-CimInstance -ClassName Win32_ComputerSystem
$product=Get-CimInstance -ClassName Win32_ComputerSystemProduct
$hardwareId=[Guid]::Empty
if($VmId -ne [Guid]'e49c7f67-9bb0-4984-acf8-acb088d8f799' -or $system.Manufacturer -cne 'QEMU' -or
   $system.Model -cne 'VeyloDriverLab' -or $env:COMPUTERNAME -cne 'VEYLO-LAB' -or
   ![Guid]::TryParse([string]$product.UUID,[ref]$hardwareId) -or $hardwareId -ne $VmId){
    throw 'Guest identity rejected: exact isolated Veylo VM UUID required.'
}
if(![Environment]::Is64BitProcess){throw 'The x64 guest PowerShell process is required.'}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'An already elevated guest token is required; no elevation is attempted.'
}
$acceptanceRoot='C:\VeyloVersionTransition'
$labRoot='C:\VeyloLab'
$Mode='VersionTransition'
$outputNames=@('version-transition.json','transition.lock','old-baseline.log','upgrade.log','restore.log',
    'rollback-native.log','rollback-native.json','old-baseline-capture.json','old-baseline-capture.log',
    'upgrade-capture.json','upgrade-capture.log','rollback-capture.json','rollback-capture.log',
    'restore-capture.json','restore-capture.log')
function Assert-CanonicalPath([string]$Path,[string]$Within,[switch]$MayNotExist){
    $full=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetFullPath($Within).TrimEnd('\')
    if($full -cnotmatch '^[A-Za-z]:\\' -or $full.Substring(3).Contains(':')){throw 'Only absolute guest paths without alternate data streams are allowed.'}
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

function Stop-BoundedGuestChild($Process){
    if($Process.HasExited){return}
    try{$Process.Kill()}catch{if(!$Process.HasExited){throw}}
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
        try{if($started -and !$process.HasExited){Stop-BoundedGuestChild $process;$null=$process.WaitForExit(5000)}}
        finally{$writer.Dispose();$process.Dispose();$watch.Stop()}
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

function Get-VersionSpec([string]$Name){
    switch -CaseSensitive ($Name){
        'old' {return @{version='0.5.0.0';sys='0b065b41ad9183acec563325ccd91b5cb284fc23387d78ecb04a521e67b8030a';
            inf='e9096173f591f0c2e749c6a4850b5df1d920ca39ece5a7097967c925a57efd7e';
            cat='8d6c7ccdc06ef7ca98503d83bc5ffdb4597a155aeb7f3b491949b30e3eb93032';
            cert='ab9b257ac6e0ae66c0a0dc107d186862513a72e4f553ebb10d3380d73dffb768';
            thumb='c382419d32c670bb86dd8e8c9c646dda2c4f0692';
            capture='1d1299b1afd9c3aa7c211c1a322cd145bc3f11b13233f2a563ea2089a43c7375';
            signing='94d2c922a3294dab60aca5866b8983ae28842ef72d7f2bdc15c3f00e80a07bd5'}}
        'current' {return @{version='0.5.1.0';sys='ee25b86fe0103faf652094fc37fb3219de44e5bfa58796e901374741c528a5d1';
            inf='483113d017a3c9189ea6d290e2c36599e2f0ef06419fc36ac4f35a705ad4f92d';
            cat='17f12aa0943d377e71b5c3639506cae3d577de08ce0e702b4bec38a05f00e611';
            cert='9d43e71dc2b22cf5c36dbc6427c5477ac93a92b12c7f2ea00c63a2644870fd5c';
            thumb='661902c5ef7c48c9274e0a4caef1323f684258c6';
            capture='83c14477f23b05d190be95c7af5c72881e7b87901ba447d7ef1fa71840a3185a';
            signing='5a58dbff9e80a70033b2dd321bd0cbe16a58288514a7bb0f23bbd6ccef4914a3'}}
        default {throw 'Unknown fixed version.'}
    }
}
function Assert-VersionPayloads{
    $names=@('driver-vm-version-transition.ps1')
    foreach($name in @('old','current')){
        $spec=Get-VersionSpec $name
        $directory=Assert-CanonicalPath (Join-Path $acceptanceRoot $name) $acceptanceRoot
        Assert-TrustedGuestAcl $directory
        $expected=@{'SesMicrophone.inf'=$spec.inf;'SesMicrophone.sys'=$spec.sys;'SesMicrophone.cat'=$spec.cat;
            'lab-test.cer'=$spec.cert;'ses_driver_capture_lab_tests.exe'=$spec.capture;'test-signing-manifest.json'=$spec.signing}
        $inventory=@(Get-ChildItem -LiteralPath $directory -Force)
        if($inventory.Count -ne 6){throw 'Fixed package inventory differs.'}
        foreach($item in $inventory){if($item.Name -cnotin @($expected.Keys)){throw 'Unexpected package file.'}}
        foreach($file in $expected.Keys){
            $names+=($name+'\'+$file)
            $path=Assert-CanonicalPath (Join-Path $directory $file) $acceptanceRoot
            Assert-TrustedGuestAcl $path
            $item=Get-Item -LiteralPath $path -Force
            if($item.PSIsContainer -or $item.Length -lt 1 -or $item.Length -gt 16MB -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$file]){
                throw ('Pinned historical/current payload differs: '+$name+'\'+$file)
            }
        }
        $signing=Read-BoundedJson (Join-Path $directory 'test-signing-manifest.json') $acceptanceRoot
        if($signing.driverVersion -cne $spec.version -or $signing.abi -ne 5 -or $signing.protocol -ne 1 -or
            $signing.testOnly -isnot [bool] -or !$signing.testOnly -or $signing.signed -isnot [bool] -or !$signing.signed -or
            $signing.certificateSha256 -cne $spec.cert -or $signing.certificateThumbprint -cne $spec.thumb){
            throw 'Pinned signing manifest contract differs.'
        }
        if($name -ceq 'old' -and $signing.sourceCommit -cne '3ba0c2b63234948600c9da9aa3ade5901f076f6f'){
            throw 'Actual historical source provenance differs.'
        }
    }
    Assert-Inventory $manifest $names $acceptanceRoot
}
function Test-TransitionCapture($Process,$Evidence){
    foreach($name in @('schema','checks','failures','unsupported','verified_endpoints','formats_passed','self_tests')){
        $property=$Evidence.PSObject.Properties[$name]
        if(!$property -or ($property.Value -isnot [int] -and $property.Value -isnot [long])){return $false}
    }
    return ($Process.exitCode -is [int] -and $Process.exitCode -eq 0 -and
        $Process.timedOut -is [bool] -and !$Process.timedOut -and
        $Process.outputLimited -is [bool] -and !$Process.outputLimited -and
        $Evidence.schema -eq 1 -and $Evidence.checks -gt 0 -and $Evidence.failures -eq 0 -and
        $Evidence.unsupported -eq 0 -and $Evidence.verified_endpoints -eq 1 -and
        $Evidence.formats_passed -eq 2 -and $Evidence.self_tests -eq 0)
}
function Read-VersionIdentity([string]$Name,[string]$ExpectedInstance){
    $spec=Get-VersionSpec $Name
    $device=Assert-OneSesDevice
    if($device.ConfigManagerErrorCode -ne 0 -or ($ExpectedInstance -and $device.DeviceID -ine $ExpectedInstance)){
        throw 'Device status or original exact instance differs.'
    }
    $rows=@(Get-CimInstance -ClassName Win32_PnPSignedDriver | Where-Object {$_.DeviceID -ieq $device.DeviceID})
    if($rows.Count -ne 1 -or $rows[0].DriverVersion -cne $spec.version){throw 'PnP installed driver version differs.'}
    $services=@(Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='SesMicrophone'")
    if($services.Count -ne 1 -or $services[0].Name -ine 'SesMicrophone' -or !$services[0].Started -or $services[0].State -cne 'Running'){
        throw 'The sole SesMicrophone service is not running.'
    }
    $image=[string]$services[0].PathName
    if($image.StartsWith('\??\',[StringComparison]::Ordinal)){$image=$image.Substring(4)}
    if($image.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase)){$image='C:\Windows\'+$image.Substring(12)}
    if($image -cnotmatch '(?i)^C:\\Windows\\System32\\(?:drivers\\SesMicrophone\.sys|DriverStore\\FileRepository\\sesmicrophone\.inf_[a-z0-9_]+\\SesMicrophone\.sys)$'){
        throw 'Service image is outside the fixed installed driver locations.'
    }
    $full=Assert-CanonicalPath $image 'C:\Windows\System32'
    $file=Get-Item -LiteralPath $full -Force
    if($file.PSIsContainer -or $file.Length -lt 1 -or $file.Length -gt 16MB){throw 'Installed service image size/type differs.'}
    $hash=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -cne $spec.sys){throw 'Actual installed service image hash differs.'}
    return @{instance=[string]$device.DeviceID;hardwareId='ROOT\SES_MICROPHONE';service='SesMicrophone';
        pnpVersion=[string]$rows[0].DriverVersion;serviceImage=$full;serviceImageSha256=$hash;state='Running'}
}
function Invoke-VersionCapture([string]$Stage,[string]$Name,[string]$Instance){
    if($Stage -cnotin @('old-baseline','upgrade','rollback','restore')){throw 'Unexpected capture stage.'}
    Assert-VersionPayloads
    $before=Read-VersionIdentity $Name $Instance
    $json=Get-OutputPath ($Stage+'-capture.json')
    if(Test-Path -LiteralPath $json){Remove-Item -LiteralPath $json}
    $process=Invoke-BoundedTool (Join-Path (Join-Path $acceptanceRoot $Name) 'ses_driver_capture_lab_tests.exe') @('--isolated-lab','--json-report',$json) ($Stage+'-capture.log') 180
    $evidence=Read-BoundedJson $json $acceptanceRoot 1MB
    if(!(Test-TransitionCapture $process $evidence)){throw ('Actual capture failed at '+$Stage)}
    $after=Read-VersionIdentity $Name $Instance
    return @{status='Passed';identityBefore=$before;identityAfter=$after;process=$process;capture=$evidence}
}
function Get-CertificateStoreInventory([string]$StoreName){
    if($StoreName -cnotin @('Root','TrustedPublisher')){throw 'Unapproved guest certificate store.'}
    $store=[Security.Cryptography.X509Certificates.X509Store]::new($StoreName,[Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    try{
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        return @($store.Certificates | ForEach-Object {$_.Thumbprint.ToLowerInvariant()} | Sort-Object)
    }finally{$store.Close();$store.Dispose()}
}
function Read-PublicCertificate([string]$Name){
    $spec=Get-VersionSpec $Name
    $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path (Join-Path $acceptanceRoot $Name) 'lab-test.cer'))
    if($cert.HasPrivateKey -or $cert.Thumbprint.ToLowerInvariant() -cne $spec.thumb -or
        $cert.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow -or $cert.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow){
        $cert.Dispose();throw 'Pinned public certificate identity/validity differs.'
    }
    return $cert
}
function Add-OldPublicCertificate($Result){
    Assert-VersionPayloads
    $current=Get-VersionSpec 'current';$old=Get-VersionSpec 'old'
    $cert=Read-PublicCertificate 'old'
    try{
        foreach($storeName in @('Root','TrustedPublisher')){
            $before=@(Get-CertificateStoreInventory $storeName)
            if($current.thumb -cnotin $before){throw 'Current pinned guest test certificate is not already trusted.'}
            $entry=@{store=('LocalMachine\'+$storeName);before=$before;after=@();allowedAddedThumbprint=$old.thumb;scopeVerified=$false}
            $Result.certificateStores+=$entry
            Write-Report 'version-transition.json' $Result 'VEYLO_VERSION_TRANSITION_RESULT'
            if($old.thumb -cnotin $before){
                $store=[Security.Cryptography.X509Certificates.X509Store]::new($storeName,[Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
                try{$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite);$store.Add($cert)}
                finally{$store.Close();$store.Dispose()}
            }
            $after=@(Get-CertificateStoreInventory $storeName);$entry.after=$after
            $expected=@($before);if($old.thumb -cnotin $expected){$expected+=,$old.thumb}
            $entry.scopeVerified=(($after -join ';') -ceq ((@($expected | Sort-Object)) -join ';'))
            Write-Report 'version-transition.json' $Result 'VEYLO_VERSION_TRANSITION_RESULT'
            if(!$entry.scopeVerified){throw 'Guest certificate store mutation exceeded the exact public certificate scope.'}
        }
    }finally{$cert.Dispose()}
}
function Invoke-FixedUpdate([string]$Name,[string]$LogName){
    Assert-VersionPayloads
    Assert-Inventory $seed $seedNames $labRoot
    $null=Assert-OneSesDevice
    # DevCon update deliberately forces this exact package on the sole matching
    # hardware ID. The older baseline is installation, not claimed API rollback.
    $script:driverMutationStarted=$true;$script:mutationUncertain=$true
    $process=Invoke-BoundedTool (Join-Path $labRoot 'devcon.exe') @('update',(Join-Path (Join-Path $acceptanceRoot $Name) 'SesMicrophone.inf'),'ROOT\SES_MICROPHONE') $LogName 90
    $script:mutationUncertain=($process.timedOut -or $process.outputLimited)
    return $process
}
function Assert-UpdateCompleted($Process){
    if($Process.timedOut -or $Process.outputLimited -or $Process.exitCode -notin @(0,1)){throw 'Fixed driver update failed or exceeded its bounds.'}
    if($Process.exitCode -eq 1){return $false}
    return $true
}
function Initialize-NativeRollback{
    if('VeyloLab.VersionRollback' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace VeyloLab {
    public static class VersionRollback {
        [StructLayout(LayoutKind.Sequential)]
        public struct DeviceInfo { public uint cbSize; public Guid ClassGuid; public uint DevInst; public UIntPtr Reserved; }
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", ExactSpelling=true, SetLastError=true)]
        private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr parent);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", EntryPoint="SetupDiOpenDeviceInfoW", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiOpenDeviceInfo(IntPtr set, string instance, IntPtr parent, uint flags, ref DeviceInfo info);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", ExactSpelling=true, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("newdev.dll", ExactSpelling=true, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DiRollbackDriver(IntPtr set, ref DeviceInfo info, IntPtr parent, uint flags, [MarshalAs(UnmanagedType.Bool)] out bool needReboot);
        public static bool Rollback(string instance) {
            if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(DeviceInfo)) != 32)
                throw new InvalidOperationException("SP_DEVINFO_DATA x64 ABI mismatch.");
            if (!System.Text.RegularExpressions.Regex.IsMatch(instance, @"\AROOT\\(?:MEDIA|SES_MICROPHONE)\\[0-9]{4}\z", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant))
                throw new ArgumentException("Exact root audio instance required.");
            Guid media = new Guid("4d36e96c-e325-11ce-bfc1-08002be10318");
            IntPtr set = SetupDiCreateDeviceInfoList(ref media, IntPtr.Zero);
            if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Create device info list failed.");
            try {
                DeviceInfo info = new DeviceInfo { cbSize = 32 };
                if (!SetupDiOpenDeviceInfo(set, instance, IntPtr.Zero, 0, ref info))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Open exact device instance failed.");
                if (info.ClassGuid != media) throw new InvalidOperationException("Exact device class differs.");
                bool reboot;
                if (!DiRollbackDriver(set, ref info, IntPtr.Zero, 0, out reboot))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DiRollbackDriver failed; no forced-install substitute is attempted.");
                return reboot;
            } finally { SetupDiDestroyDeviceInfoList(set); }
        }
    }
}
'@
}
# Full trust/identity verification occurs in each native child as well as Run.
$manifest=Read-BoundedJson (Join-Path $acceptanceRoot 'version-transition-manifest.json') $acceptanceRoot
Assert-TrustedGuestAcl $acceptanceRoot
Assert-TrustedGuestAcl (Join-Path $acceptanceRoot 'version-transition-manifest.json')
$manifestId=[Guid]::Empty
if(($manifest.schema -isnot [int] -and $manifest.schema -isnot [long]) -or $manifest.schema -ne 1 -or $manifest.testOnly -isnot [bool] -or !$manifest.testOnly -or
    $manifest.productionReady -isnot [bool] -or $manifest.productionReady -or
    $manifest.oldVersion -cne '0.5.0.0' -or $manifest.currentVersion -cne '0.5.1.0' -or
    ($manifest.abi -isnot [int] -and $manifest.abi -isnot [long]) -or $manifest.abi -ne 5 -or
    ($manifest.protocol -isnot [int] -and $manifest.protocol -isnot [long]) -or $manifest.protocol -ne 1 -or
    $manifest.oldSourceCommit -cne '3ba0c2b63234948600c9da9aa3ade5901f076f6f' -or
    ![Guid]::TryParseExact([string]$manifest.vmId,'D',[ref]$manifestId) -or $manifestId -ne $VmId){throw 'Version-transition manifest identity rejected.'}
$ownPath=Assert-CanonicalPath $PSCommandPath $acceptanceRoot
if($ownPath -ine (Join-Path $acceptanceRoot 'driver-vm-version-transition.ps1')){throw 'Runner fixed guest path required.'}
Assert-VersionPayloads
$seed=Read-BoundedJson (Join-Path $labRoot 'veylo-lab-seed.json') $labRoot
Assert-TrustedGuestAcl $labRoot
Assert-TrustedGuestAcl (Join-Path $labRoot 'veylo-lab-seed.json')
$seedId=[Guid]::Empty
if($seed.schema -ne 1 -or $seed.testOnly -isnot [bool] -or !$seed.testOnly -or
    ![Guid]::TryParseExact([string]$seed.id,'D',[ref]$seedId) -or $seedId -ne $VmId){throw 'Original seed identity rejected.'}
$seedNames=@('SesMicrophone.inf','SesMicrophone.sys','SesMicrophone.cat','SYSVAD-LICENSE','lab-test.cer',
    'ses_driver_lab_tests.exe','ses_driver_capture_lab_tests.exe','DRIVER.md','DRIVER-LAB.md','LICENSE',
    'README-TEST-SIGNED.txt','test-signing-manifest.json','devcon.exe','guest.ps1')
Assert-Inventory $seed $seedNames $labRoot
if($Operation -ceq 'RollbackNative'){
    if($RunId -eq [Guid]::Empty){throw 'Native child requires its paired run identity.'}
    $parent=Read-BoundedJson (Get-OutputPath 'version-transition.json') $acceptanceRoot 1MB
    Assert-TrustedGuestAcl (Get-OutputPath 'version-transition.json')
    if($parent.runId -cne $RunId.ToString('D') -or $parent.vmId -cne $VmId.ToString('D') -or
        $parent.status -cne 'Running' -or $parent.stage -cne 'rollback-native' -or
        [DateTime]::Parse([string]$parent.utc).ToUniversalTime() -lt [DateTime]::UtcNow.AddMinutes(-10)){
        throw 'Native rollback requires the current protected pending parent stage.'
    }
    # A fresh report alone cannot authorize replay after the parent died.
    # The parent holds this exact protected lock for the entire transition.
    $locked=$false;$probe=$null
    try{$probe=[IO.File]::Open((Get-OutputPath 'transition.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch [IO.IOException]{if(($_.Exception.HResult -band 0xffff) -eq 32){$locked=$true}else{throw}}
    finally{if($probe){$probe.Dispose()}}
    if(!$locked){throw 'Native rollback parent transition lock is not held.'}
    $before=Read-VersionIdentity 'current' ([string]$parent.instance)
    Initialize-NativeRollback
    $reboot=[VeyloLab.VersionRollback]::Rollback([string]$before.instance)
    $native=@{schema=1;vmId=$VmId.ToString('D');runId=$RunId.ToString('D');api='DiRollbackDriver';
        instance=$before.instance;rebootRequired=$reboot;utc=[DateTime]::UtcNow.ToString('o');
        status=($(if($reboot){'NeedsReboot'}else{'Passed'}));testOnly=$true;productionReady=$false}
    Write-Report 'rollback-native.json' $native 'VEYLO_VERSION_ROLLBACK_NATIVE'
    exit 0
}
if($RunId -ne [Guid]::Empty){throw 'Run identity is generated internally for the full transition.'}
$lockPath=Get-OutputPath 'transition.lock'
$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    Assert-TrustedGuestAcl $lockPath
    $RunId=[Guid]::NewGuid()
    $script:driverMutationStarted=$false;$script:mutationUncertain=$false;$restoreAttempted=$false
    $result=[ordered]@{schema=1;vmId=$VmId.ToString('D');runId=$RunId.ToString('D');testOnly=$true;
        productionReady=$false;status='Running';stage='preflight';utc=[DateTime]::UtcNow.ToString('o');
        rebootRequired=$false;baselineIsRollback=$false;apiRollbackVerified=$false;currentRestored=$false;
        driverMutationUncertain=$false;certificateStores=@();stages=@()}
    # Immediately invalidate any stale Passed summary, before certificate/driver changes.
    Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
    try{
        $device=Assert-OneSesDevice;$result.instance=[string]$device.DeviceID
        $result.initialIdentity=Read-VersionIdentity 'current' ([string]$result.instance)
        $currentCertificate=Read-PublicCertificate 'current'
        $currentCertificate.Dispose()
        Add-OldPublicCertificate $result
        foreach($stage in @('old-baseline','upgrade','rollback','restore')){
            $result.stage=$stage;$result.utc=[DateTime]::UtcNow.ToString('o')
            Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
            if($stage -ceq 'rollback'){
                $result.stage='rollback-native'
                Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
                $nativePath=Get-OutputPath 'rollback-native.json'
                if(Test-Path -LiteralPath $nativePath){Remove-Item -LiteralPath $nativePath}
                $powershell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
                $null=Assert-CanonicalPath $powershell 'C:\Windows\System32'
                $script:mutationUncertain=$true
                $process=Invoke-BoundedTool $powershell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$ownPath,'-VmId',$VmId.ToString('D'),'-Operation','RollbackNative','-RunId',$RunId.ToString('D')) 'rollback-native.log' 120
                $script:mutationUncertain=($process.timedOut -or $process.outputLimited)
                if($process.exitCode -ne 0 -or $process.timedOut -or $process.outputLimited){throw 'Native rollback child failed or exceeded its bounds.'}
                $native=Read-BoundedJson $nativePath $acceptanceRoot
                Assert-TrustedGuestAcl $nativePath
                if($native.schema -ne 1 -or $native.vmId -cne $VmId.ToString('D') -or $native.runId -cne $RunId.ToString('D') -or
                    $native.api -cne 'DiRollbackDriver' -or $native.instance -ine $result.instance -or
                    $native.testOnly -isnot [bool] -or !$native.testOnly -or $native.productionReady -isnot [bool] -or $native.productionReady -or
                    $native.rebootRequired -isnot [bool] -or $native.status -cnotin @('Passed','NeedsReboot')){throw 'Unpaired or invalid native rollback report.'}
                $result.nativeRollback=$native
                if($native.rebootRequired){$result.rebootRequired=$true;$result.status='NeedsReboot';break}
                if($native.status -cne 'Passed'){throw 'Native rollback did not complete.'}
                $name='old'
            }else{
                if($stage -ceq 'restore'){$restoreAttempted=$true}
                $name=if($stage -ceq 'old-baseline'){'old'}else{'current'}
                $log=if($stage -ceq 'old-baseline'){'old-baseline.log'}elseif($stage -ceq 'upgrade'){'upgrade.log'}else{'restore.log'}
                $process=Invoke-FixedUpdate $name $log
                $completed=Assert-UpdateCompleted $process
                $result.stages+=@{stage=$stage;operation='DevCon update exact hardware';process=$process;completed=$completed}
                if(!$completed){$result.rebootRequired=$true;$result.status='NeedsReboot';break}
            }
            $capture=Invoke-VersionCapture $stage $name ([string]$result.instance)
            $result.stages+=@{stage=$stage;expectedVersion=(Get-VersionSpec $name).version;status='Passed';capture=$capture}
            if($stage -ceq 'rollback'){$result.apiRollbackVerified=$true}
            if($stage -ceq 'restore'){$result.currentRestored=$true}
            Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
        }
        if($result.status -ceq 'Running'){
            if(!$result.apiRollbackVerified -or !$result.currentRestored -or @($result.stages | Where-Object {$_.ContainsKey('status') -and $_.status -ceq 'Passed'}).Count -ne 4){throw 'Incomplete transition evidence.'}
            $result.stage='complete';$result.status='Passed'
        }
    }catch{
        $result.status='Findings';$result.error=$_.Exception.Message
        # A bounded child that was killed may have an in-flight kernel operation.
        # Do not run another driver mutation or claim restoration in that state.
        if($script:driverMutationStarted -and !$script:mutationUncertain -and !$result.rebootRequired -and !$restoreAttempted){
            $result.stage='failure-restore';$result.utc=[DateTime]::UtcNow.ToString('o')
            Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
            try{
                $restoreProcess=Invoke-FixedUpdate 'current' 'restore.log'
                $completed=Assert-UpdateCompleted $restoreProcess
                if(!$completed){$result.rebootRequired=$true;$result.status='NeedsReboot'}
                else{
                    $restoreCapture=Invoke-VersionCapture 'restore' 'current' ([string]$result.instance)
                    $result.currentRestored=$true
                    $result.failureRestore=@{status='Passed';process=$restoreProcess;capture=$restoreCapture}
                }
            }catch{$result.failureRestore=@{status='Findings';error=$_.Exception.Message}}
        }
        elseif($script:driverMutationStarted){$result.restoreSkipped='Reboot, uncertain in-flight mutation, or already attempted final restoration requires explicit guest inspection.'}
    }
    $result.driverMutationUncertain=$script:mutationUncertain
    $result.utc=[DateTime]::UtcNow.ToString('o')
    Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
    if($result.status -ceq 'NeedsReboot'){exit 2}
    if($result.status -cne 'Passed'){exit 1}
}finally{$lock.Dispose()}
