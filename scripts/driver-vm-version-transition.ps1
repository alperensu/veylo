# Guest-only historical version transition. Never execute/dot-source on the daily host.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Guid]$VmId,
    [ValidateSet('Run','Resume','RollbackNative','IdentityNative')][string]$Operation='Run',
    [Guid]$RunId=[Guid]::Empty,
    [Guid]$RequestId=[Guid]::Empty
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
# The entire host rejection is read-only and precedes writes, native imports and processes.
$system=Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 5
$product=Get-CimInstance -ClassName Win32_ComputerSystemProduct -OperationTimeoutSec 5
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
    'restore-capture.json','restore-capture.log','identity-native.json','identity-native.log',
    'resume-upgrade-checkpoint.json','resume-rollback-checkpoint.json','resume-restore-checkpoint.json')
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

function Convert-DriverJson([string]$Raw){
    # PowerShell 7.5+ otherwise converts ISO report strings into DateTime values.
    # Keep the same strict wire types as Windows PowerShell 5.1.
    $parameters=@{}
    if((Get-Command ConvertFrom-Json -CommandType Cmdlet).Parameters.ContainsKey('DateKind')){$parameters.DateKind='String'}
    return ($Raw | ConvertFrom-Json @parameters)
}
function Read-BoundedJson([string]$Path,[string]$Within,[int]$Limit=65536){
    $full=Assert-CanonicalPath $Path $Within
    $file=Get-Item -LiteralPath $full -Force
    if($file.PSIsContainer -or $file.Length -lt 2 -or $file.Length -gt $Limit){throw 'Invalid JSON file size/type.'}
    return (Convert-DriverJson (Get-Content -LiteralPath $full -Raw))
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
    return @(Get-CimInstance -ClassName Win32_PnPEntity -OperationTimeoutSec 5 | Where-Object {
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
    return (($Process.exitCode -is [int] -or $Process.exitCode -is [long]) -and $Process.exitCode -eq 0 -and
        $Process.timedOut -is [bool] -and !$Process.timedOut -and
        $Process.outputLimited -is [bool] -and !$Process.outputLimited -and
        $Evidence.schema -eq 1 -and $Evidence.checks -gt 0 -and $Evidence.failures -eq 0 -and
        $Evidence.unsupported -eq 0 -and $Evidence.verified_endpoints -eq 1 -and
        $Evidence.formats_passed -eq 2 -and $Evidence.self_tests -eq 0)
}
function Get-PnpDeviceFilter([string]$Instance){
    if(!$Instance -or ![regex]::IsMatch($Instance,'\AROOT\\(?:MEDIA|SES_MICROPHONE)\\[0-9]{4}\z',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)){
        throw 'PnP query requires the validated exact root audio instance.'
    }
    # WQL uses backslash escapes, independent of PowerShell string quoting.
    $escaped=$Instance.Replace('\','\\').Replace("'","\'")
    return ("DeviceID='"+$escaped+"'")
}
function Test-IdentityParentStage($Parent){
    if(!$Parent.PSObject.Properties['status'] -or !$Parent.PSObject.Properties['stage']){return $false}
    return (($Parent.status -ceq 'Running' -and $Parent.stage -cin @('preflight','old-baseline','upgrade','rollback-native','restore')) -or
        ($Parent.status -ceq 'Findings' -and $Parent.stage -ceq 'failure-restore'))
}
function Assert-IdentityRequest($Parent,[Guid]$ExpectedRequest,[string]$ExpectedInstance){
    $request=$Parent.identityRequest
    $stamp=[DateTimeOffset]::MinValue
    if($RunId -eq [Guid]::Empty -or $ExpectedRequest -eq [Guid]::Empty -or
        $Parent.runId -cne $RunId.ToString('D') -or $Parent.vmId -cne $VmId.ToString('D') -or
        !(Test-IdentityParentStage $Parent) -or $Parent.instance -ine $ExpectedInstance -or
        $request.requestId -cne $ExpectedRequest.ToString('D') -or $request.instance -ine $ExpectedInstance -or
        !$ExpectedInstance -or ![regex]::IsMatch($ExpectedInstance,'\AROOT\\(?:MEDIA|SES_MICROPHONE)\\[0-9]{4}\z',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        ![DateTimeOffset]::TryParseExact([string]$request.utc,'o',[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,[ref]$stamp) -or
        $stamp -lt [DateTimeOffset]::UtcNow.AddSeconds(-10) -or $stamp -gt [DateTimeOffset]::UtcNow.AddSeconds(1)){
        throw 'Native identity request is unpaired, foreign, or stale.'
    }
    return $stamp
}
function Assert-IdentityParentLock{
    $locked=$false;$probe=$null
    try{$probe=[IO.File]::Open((Get-OutputPath 'transition.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch [IO.IOException]{if(($_.Exception.HResult -band 0xffff) -eq 32){$locked=$true}else{throw}}
    finally{if($probe){$probe.Dispose()}}
    if(!$locked){throw 'Native identity parent transition lock is not held.'}
}
function Convert-NativeIdentityReport([string]$Raw,[Guid]$ExpectedRequest,[string]$ExpectedInstance,[DateTimeOffset]$NotBefore){
    # This is a flat fixed report. Reject duplicate or escaped keys before the
    # Windows PowerShell JSON parser can silently select a duplicate's last value.
    $names=@('schema','vmId','runId','requestId','instance','api','nativeVersion','nativeInfName','utc','status','testOnly','productionReady')
    $keys=[regex]::Matches($Raw,'"(?<key>(?:[^"\\]|\\.)*)"\s*:')
    if($Raw.Length -gt 4096 -or $keys.Count -ne $names.Count){throw 'Native identity report field count differs.'}
    $seen=@{}
    foreach($key in $keys){$name=$key.Groups['key'].Value;if($name -cnotin $names -or $seen.ContainsKey($name)){throw 'Native identity duplicate/unknown/escaped report key.'};$seen[$name]=$true}
    $evidence=Convert-DriverJson $Raw
    $utc=[DateTimeOffset]::MinValue
    foreach($name in @('vmId','runId','requestId','instance','api','nativeVersion','nativeInfName','utc','status')){
        if($evidence.$name -isnot [string]){throw 'Native identity report string field has the wrong type.'}
    }
    if(($evidence.schema -isnot [int] -and $evidence.schema -isnot [long]) -or $evidence.schema -ne 1 -or
        $evidence.vmId -cne $VmId.ToString('D') -or $evidence.runId -cne $RunId.ToString('D') -or
        $ExpectedRequest -eq [Guid]::Empty -or $evidence.requestId -cne $ExpectedRequest.ToString('D') -or
        $evidence.instance -ine $ExpectedInstance -or $evidence.api -cne 'SetupDiGetDevicePropertyW' -or $evidence.status -cne 'Passed' -or
        $evidence.testOnly -isnot [bool] -or !$evidence.testOnly -or $evidence.productionReady -isnot [bool] -or $evidence.productionReady -or
        ![regex]::IsMatch($evidence.nativeVersion,'\A[0-9]{1,5}(?:\.[0-9]{1,5}){3}\z') -or
        ![regex]::IsMatch($evidence.nativeInfName,'\Aoem[0-9]{1,4}\.inf\z',[Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        ![DateTimeOffset]::TryParseExact($evidence.utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$utc) -or
        $utc -lt $NotBefore -or $utc -gt [DateTimeOffset]::UtcNow.AddSeconds(1) -or $utc -lt [DateTimeOffset]::UtcNow.AddSeconds(-10)){
        throw 'Unpaired or invalid native identity report.'
    }
    foreach($part in $evidence.nativeVersion.Split('.')){if([int]$part -gt 65535){throw 'Native version component exceeds WORD range.'}}
    return $evidence
}
function Read-NativeVersionIdentity([string]$ExpectedInstance){
    $null=Get-PnpDeviceFilter $ExpectedInstance
    $parentPath=Get-OutputPath 'version-transition.json'
    Assert-TrustedGuestAcl $parentPath
    $parent=Read-BoundedJson $parentPath $acceptanceRoot 1MB
    if($parent.runId -cne $RunId.ToString('D') -or $parent.vmId -cne $VmId.ToString('D') -or
        !(Test-IdentityParentStage $parent) -or $parent.instance -ine $ExpectedInstance){throw 'Native identity parent does not describe the original active instance.'}
    Assert-IdentityParentLock
    $request=[Guid]::NewGuid();$notBefore=[DateTimeOffset]::UtcNow
    $parent | Add-Member -MemberType NoteProperty -Name identityRequest -Value ([ordered]@{
        requestId=$request.ToString('D');instance=$ExpectedInstance;utc=$notBefore.ToString('o')}) -Force
    Write-Report 'version-transition.json' $parent 'VEYLO_VERSION_IDENTITY_REQUEST'
    $path=Get-OutputPath 'identity-native.json'
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
    $powershell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $null=Assert-CanonicalPath $powershell 'C:\Windows\System32'
    # Never set/clear mutation uncertainty for a strictly read-only child.
    try{
        $process=Invoke-BoundedTool $powershell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$ownPath,
            '-VmId',$VmId.ToString('D'),'-Operation','IdentityNative','-RunId',$RunId.ToString('D'),'-RequestId',$request.ToString('D')) 'identity-native.log' 10
    }catch{$_.Exception.Data['VeyloIdentityChildUncertain']=$true;throw}
    if($process.exitCode -ne 0 -or $process.timedOut -or $process.outputLimited -or $process.elapsedSeconds -ge 10){
        $failure=[InvalidOperationException]::new(('Read-only native identity child failed or exceeded its ten-second bound: '+($process | ConvertTo-Json -Compress)))
        $failure.Data['VeyloIdentityChildUncertain']=$true;throw $failure
    }
    $file=Get-Item -LiteralPath (Assert-CanonicalPath $path $acceptanceRoot) -Force
    Assert-TrustedGuestAcl $path
    if($file.PSIsContainer -or $file.Length -lt 2 -or $file.Length -gt 4096){throw 'Native identity report size/type differs.'}
    $evidence=Convert-NativeIdentityReport ([IO.File]::ReadAllText($path)) $request $ExpectedInstance $notBefore
    $evidence | Add-Member -MemberType NoteProperty -Name process -Value $process
    return $evidence
}
function Get-InstalledInfHash([string]$InfName){
    if(!$InfName -or ![regex]::IsMatch($InfName,'\Aoem[0-9]{1,4}\.inf\z',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)){
        throw 'Only the exact installed published OEM INF basename is allowed.'
    }
    $path=Assert-CanonicalPath (Join-Path 'C:\Windows\INF' $InfName) 'C:\Windows\INF'
    $file=Get-Item -LiteralPath $path -Force
    if($file.PSIsContainer -or $file.Length -lt 1 -or $file.Length -gt 16MB){throw 'Installed INF size/type differs.'}
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Read-VersionObservation([string]$ExpectedInstance){
    $device=Assert-OneSesDevice
    if($ExpectedInstance -and $device.DeviceID -ine $ExpectedInstance){
        throw ('Original exact device instance differs; expected '+$ExpectedInstance+'; observed '+$device.DeviceID+'; settling is forbidden.')
    }
    $filter=Get-PnpDeviceFilter ([string]$device.DeviceID)
    $pnpError=$null
    try{$rows=@(Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter $filter -OperationTimeoutSec 5)}
    catch{$rows=@();$pnpError=$_.Exception.Message}
    foreach($row in $rows){if($row.DeviceID -ine $device.DeviceID){throw 'Filtered PnP provider returned another device identity.'}}
    if($rows.Count -gt 1){throw 'Multiple installed PnP driver rows for the exact instance; settling is forbidden.'}
    $services=@(Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='SesMicrophone'" -OperationTimeoutSec 5)
    if($services.Count -gt 1 -or ($services.Count -eq 1 -and $services[0].Name -ine 'SesMicrophone')){
        throw 'Service identity is not the sole fixed SesMicrophone service; settling is forbidden.'
    }
    $observation=@{instance=[string]$device.DeviceID;hardwareId='ROOT\SES_MICROPHONE';service='SesMicrophone';
        deviceStatus=[int]$device.ConfigManagerErrorCode;pnpRowCount=$rows.Count;pnpVersion=$null;pnpDiagnosticError=$pnpError;
        nativeVersion=$null;nativeInfName=$null;nativeInfSha256=$null;nativeIdentity=$null;
        serviceRowCount=$services.Count;serviceImage=$null;serviceImageSha256=$null;state='Missing';started=$false}
    if($rows.Count -eq 1){$observation.pnpVersion=[string]$rows[0].DriverVersion}
    if($services.Count -eq 1){
        $observation.state=[string]$services[0].State;$observation.started=[bool]$services[0].Started
        $image=[string]$services[0].PathName
        if($image.StartsWith('\??\',[StringComparison]::Ordinal)){$image=$image.Substring(4)}
        if($image.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase)){$image='C:\Windows\'+$image.Substring(12)}
        if(![regex]::IsMatch($image,'\AC:\\Windows\\System32\\(?:drivers\\SesMicrophone\.sys|DriverStore\\FileRepository\\sesmicrophone\.inf_[a-z0-9_]+\\SesMicrophone\.sys)\z',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)){
            throw 'Service image is outside the fixed installed driver locations.'
        }
        $full=Assert-CanonicalPath $image 'C:\Windows\System32'
        $file=Get-Item -LiteralPath $full -Force
        if($file.PSIsContainer -or $file.Length -lt 1 -or $file.Length -gt 16MB){throw 'Installed service image size/type differs.'}
        $observation.serviceImage=$full
        $observation.serviceImageSha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $native=Read-NativeVersionIdentity ([string]$device.DeviceID)
    $observation.nativeVersion=$native.nativeVersion;$observation.nativeInfName=$native.nativeInfName
    $observation.nativeInfSha256=Get-InstalledInfHash $native.nativeInfName;$observation.nativeIdentity=$native
    return $observation
}
function Read-VersionIdentity([string]$Name,[string]$ExpectedInstance){
    $spec=Get-VersionSpec $Name
    $observed=Read-VersionObservation $ExpectedInstance
    if($observed.deviceStatus -ne 0 -or $observed.nativeVersion -cne $spec.version -or $observed.nativeInfSha256 -cne $spec.inf -or
        $observed.serviceRowCount -ne 1 -or !$observed.started -or $observed.state -cne 'Running' -or
        $observed.serviceImageSha256 -cne $spec.sys){
        $failure=[InvalidOperationException]::new(('Installed identity differs; expected '+$spec.version+'; observed '+($observed | ConvertTo-Json -Compress)))
        $failure.Data['VeyloIdentityPending']=$true;$failure.Data['observation']=$observed
        throw $failure
    }
    return $observed
}
function Wait-VersionIdentity([string]$Name,[string]$ExpectedInstance,[ValidateRange(1,30)][int]$DeadlineSeconds=30){
    if(!$ExpectedInstance -or ![regex]::IsMatch($ExpectedInstance,'\AROOT\\(?:MEDIA|SES_MICROPHONE)\\[0-9]{4}\z',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)){
        throw 'Settling requires the original exact root audio instance.'
    }
    $spec=Get-VersionSpec $Name
    $watch=[Diagnostics.Stopwatch]::StartNew();$consecutive=0
    $script:lastVersionSettle=@{status='Running';expectedVersion=$spec.version;expectedSysSha256=$spec.sys;expectedInfSha256=$spec.inf;
        instance=$ExpectedInstance;deadlineSeconds=$DeadlineSeconds;attempts=0;elapsedSeconds=0;
        consecutiveMatches=0;observation=$null;error=$null}
    try{
        while($watch.Elapsed.TotalSeconds -lt $DeadlineSeconds){
            $script:lastVersionSettle.attempts++
            try{
                $identity=Read-VersionIdentity $Name $ExpectedInstance
                $script:lastVersionSettle.observation=$identity;$script:lastVersionSettle.error=$null
                $consecutive++
            }catch{
                $script:lastVersionSettle.error=$_.Exception.Message
                if($_.Exception.Data.Contains('observation')){$script:lastVersionSettle.observation=$_.Exception.Data['observation']}
                if(!$_.Exception.Data.Contains('VeyloIdentityPending') -or $_.Exception.Data['VeyloIdentityPending'] -ne $true){
                    $script:lastVersionSettle.status='Findings';throw
                }
                $consecutive=0
            }
            $script:lastVersionSettle.elapsedSeconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
            $script:lastVersionSettle.consecutiveMatches=$consecutive
            # Neither slow CIM nor the ten-second native child may yield a late pass.
            if($watch.Elapsed.TotalSeconds -ge $DeadlineSeconds){break}
            if($consecutive -ge 2){$script:lastVersionSettle.status='Passed';return $script:lastVersionSettle}
            $remaining=[int][math]::Floor(($DeadlineSeconds-$watch.Elapsed.TotalSeconds)*1000)
            if($remaining -gt 0){Start-Sleep -Milliseconds ([math]::Min(250,$remaining))}
        }
        $script:lastVersionSettle.status='Findings'
        $script:lastVersionSettle.error='Settling deadline expired before two timely consecutive matches. '+[string]$script:lastVersionSettle.error
        throw ('Installed version did not settle within its deadline: '+($script:lastVersionSettle | ConvertTo-Json -Depth 4 -Compress))
    }finally{
        $script:lastVersionSettle.elapsedSeconds=[math]::Round($watch.Elapsed.TotalSeconds,3);$watch.Stop()
    }
}
function Invoke-VersionCapture([string]$Stage,[string]$Name,[string]$Instance){
    $script:lastVersionSettle=$null
    if($Stage -cnotin @('old-baseline','upgrade','rollback','restore')){throw 'Unexpected capture stage.'}
    Assert-VersionPayloads
    $settle=Wait-VersionIdentity $Name $Instance
    $before=$settle.observation
    $json=Get-OutputPath ($Stage+'-capture.json')
    if(Test-Path -LiteralPath $json){Remove-Item -LiteralPath $json}
    $process=Invoke-BoundedTool (Join-Path (Join-Path $acceptanceRoot $Name) 'ses_driver_capture_lab_tests.exe') @('--isolated-lab','--json-report',$json) ($Stage+'-capture.log') 180
    $evidence=Read-BoundedJson $json $acceptanceRoot 1MB
    if(!(Test-TransitionCapture $process $evidence)){throw ('Actual capture failed at '+$Stage)}
    $after=Read-VersionIdentity $Name $Instance
    return @{status='Passed';settle=$settle;identityBefore=$before;identityAfter=$after;process=$process;capture=$evidence;
        jsonSha256=(Get-FileHash -LiteralPath $json -Algorithm SHA256).Hash.ToLowerInvariant();toolSha256=(Get-VersionSpec $Name).capture}
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
    $script:lastVersionSettle=$null
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
function Get-RecordedField($Object,[string]$Name,[type]$Type=$null){
    if($Object -is [Collections.IDictionary]){
        if(!$Object.Contains($Name)){throw ('Missing protected evidence field: '+$Name)};$value=$Object[$Name]
    }else{
        $property=$Object.PSObject.Properties[$Name]
        if(!$property){throw ('Missing protected evidence field: '+$Name)};$value=$property.Value
    }
    if($Type -eq [int] -and $value -is [long] -and $value -ge [int]::MinValue -and $value -le [int]::MaxValue){return [int]$value}
    if($Type -and !($value -is $Type)){throw ('Protected evidence field type differs: '+$Name)}
    return $value
}
function Convert-RecordedUtc($Value){
    $stamp=[DateTimeOffset]::MinValue
    if($Value -isnot [string] -or ![DateTimeOffset]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,[ref]$stamp) -or $stamp -gt [DateTimeOffset]::UtcNow.AddSeconds(1)){
        throw 'Protected evidence UTC has an invalid type, format, or future value.'
    }
    return $stamp
}
function Get-GuestBootUtc{
    $rows=@(Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 5)
    if($rows.Count -ne 1 -or $rows[0].LastBootUpTime -isnot [DateTime]){throw 'Exact guest boot-time evidence is unavailable.'}
    return $rows[0].LastBootUpTime.ToUniversalTime().ToString('o')
}
function Get-RebootCheckpointName([string]$Stage){
    switch -CaseSensitive ($Stage){
        'upgrade' {return 'resume-upgrade-checkpoint.json'}
        'rollback-native' {return 'resume-rollback-checkpoint.json'}
        'restore' {return 'resume-restore-checkpoint.json'}
        default {throw 'Only upgrade, native rollback, or final restore reboot checkpoints can resume.'}
    }
}
function Assert-RecordedProcess($Process,[string]$Log,[int]$Deadline,[int]$Exit){
    if((Get-RecordedField $Process 'exitCode' ([int])) -ne $Exit -or
        (Get-RecordedField $Process 'timedOut' ([bool])) -or (Get-RecordedField $Process 'outputLimited' ([bool])) -or
        (Get-RecordedField $Process 'deadlineSeconds' ([int])) -ne $Deadline -or
        (Get-RecordedField $Process 'log' ([string])) -cne $Log){throw 'Protected process evidence is not the completed bounded exact operation.'}
    $elapsed=Get-RecordedField $Process 'elapsedSeconds';$bytes=Get-RecordedField $Process 'bytes'
    if(($elapsed -isnot [int] -and $elapsed -isnot [long] -and $elapsed -isnot [double] -and $elapsed -isnot [decimal]) -or
        [double]::IsNaN([double]$elapsed) -or [double]::IsInfinity([double]$elapsed) -or
        $elapsed -lt 0 -or $elapsed -ge $Deadline -or ($bytes -isnot [int] -and $bytes -isnot [long]) -or $bytes -lt 0 -or $bytes -gt 1MB){
        throw 'Protected process elapsed/output bounds differ.'
    }
}
function Assert-RecordedIdentity($Identity,[string]$Name,$Report){
    $spec=Get-VersionSpec $Name
    if((Get-RecordedField $Identity 'instance' ([string])) -ine $Report.instance -or
        (Get-RecordedField $Identity 'hardwareId' ([string])) -cne 'ROOT\SES_MICROPHONE' -or
        (Get-RecordedField $Identity 'service' ([string])) -cne 'SesMicrophone' -or
        (Get-RecordedField $Identity 'deviceStatus' ([int])) -ne 0 -or
        (Get-RecordedField $Identity 'serviceRowCount' ([int])) -ne 1 -or
        !(Get-RecordedField $Identity 'started' ([bool])) -or (Get-RecordedField $Identity 'state' ([string])) -cne 'Running' -or
        (Get-RecordedField $Identity 'nativeVersion' ([string])) -cne $spec.version -or
        (Get-RecordedField $Identity 'nativeInfSha256' ([string])) -cne $spec.inf -or
        (Get-RecordedField $Identity 'serviceImageSha256' ([string])) -cne $spec.sys){throw 'Protected historical identity does not match the pinned running version.'}
    $image=Get-RecordedField $Identity 'serviceImage' ([string])
    if(![regex]::IsMatch($image,'\AC:\\Windows\\System32\\(?:drivers\\SesMicrophone\.sys|DriverStore\\FileRepository\\sesmicrophone\.inf_[a-z0-9_]+\\SesMicrophone\.sys)\z',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)){
        throw 'Protected historical SYS path differs.'
    }
    $native=Get-RecordedField $Identity 'nativeIdentity';$request=[Guid]::Empty
    if((Get-RecordedField $native 'schema' ([int])) -ne 1 -or
        (Get-RecordedField $native 'runId' ([string])) -cne $Report.runId -or (Get-RecordedField $native 'vmId' ([string])) -cne $Report.vmId -or
        (Get-RecordedField $native 'api' ([string])) -cne 'SetupDiGetDevicePropertyW' -or
        (Get-RecordedField $native 'instance' ([string])) -ine $Report.instance -or
        (Get-RecordedField $native 'nativeVersion' ([string])) -cne $spec.version -or
        (Get-RecordedField $native 'nativeInfName' ([string])) -cne (Get-RecordedField $Identity 'nativeInfName' ([string])) -or
        ![regex]::IsMatch($native.nativeInfName,'\Aoem[0-9]{1,4}\.inf\z',[Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
        (Get-RecordedField $native 'status' ([string])) -cne 'Passed' -or
        !(Get-RecordedField $native 'testOnly' ([bool])) -or (Get-RecordedField $native 'productionReady' ([bool])) -or
        ![Guid]::TryParseExact((Get-RecordedField $native 'requestId' ([string])),'D',[ref]$request) -or $request -eq [Guid]::Empty){
        throw 'Protected native identity evidence is unpaired or invalid.'
    }
    $stamp=Convert-RecordedUtc (Get-RecordedField $native 'utc' ([string]))
    if($stamp -gt (Convert-RecordedUtc $Report.utc)){throw 'Historical native identity occurs after its pending report.'}
    Assert-RecordedProcess (Get-RecordedField $native 'process') 'identity-native.log' 10 0
}
function Assert-RecordedCapture($Entry,[string]$Stage,[string]$Name,$Report,[bool]$Legacy){
    $spec=Get-VersionSpec $Name
    if((Get-RecordedField $Entry 'stage' ([string])) -cne $Stage -or (Get-RecordedField $Entry 'status' ([string])) -cne 'Passed' -or
        (Get-RecordedField $Entry 'expectedVersion' ([string])) -cne $spec.version){throw 'Protected capture stage/order/version differs.'}
    $capture=Get-RecordedField $Entry 'capture'
    if((Get-RecordedField $capture 'status' ([string])) -cne 'Passed'){throw 'Protected phase capture is incomplete.'}
    $process=Get-RecordedField $capture 'process';$evidence=Get-RecordedField $capture 'capture'
    Assert-RecordedProcess $process ($Stage+'-capture.log') 180 0
    if(!(Test-TransitionCapture $process $evidence) -or $evidence.checks -lt 20){throw 'Protected capture lacks the real minimum twenty checks and both PCM formats.'}
    $settle=Get-RecordedField $capture 'settle'
    if((Get-RecordedField $settle 'status' ([string])) -cne 'Passed' -or
        (Get-RecordedField $settle 'expectedVersion' ([string])) -cne $spec.version -or
        (Get-RecordedField $settle 'expectedInfSha256' ([string])) -cne $spec.inf -or
        (Get-RecordedField $settle 'expectedSysSha256' ([string])) -cne $spec.sys -or
        (Get-RecordedField $settle 'instance' ([string])) -ine $Report.instance -or
        (Get-RecordedField $settle 'deadlineSeconds' ([int])) -ne 30 -or
        (Get-RecordedField $settle 'consecutiveMatches' ([int])) -lt 2 -or (Get-RecordedField $settle 'attempts' ([int])) -lt 2){throw 'Protected capture settling is incomplete.'}
    $elapsed=Get-RecordedField $settle 'elapsedSeconds'
    if(($elapsed -isnot [int] -and $elapsed -isnot [long] -and $elapsed -isnot [double] -and $elapsed -isnot [decimal]) -or
        [double]::IsNaN([double]$elapsed) -or [double]::IsInfinity([double]$elapsed) -or $elapsed -lt 0 -or $elapsed -ge 30){throw 'Protected settling evidence is late or malformed.'}
    foreach($identity in @($capture.identityBefore,$capture.identityAfter,$settle.observation)){Assert-RecordedIdentity $identity $Name $Report}
    $path=Get-OutputPath ($Stage+'-capture.json');Assert-TrustedGuestAcl $path
    $actual=Read-BoundedJson $path $acceptanceRoot 1MB
    if(($actual | ConvertTo-Json -Depth 14 -Compress) -cne ($evidence | ConvertTo-Json -Depth 14 -Compress)){
        throw 'Protected actual capture file and recorded capture differ.'
    }
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if(!$Legacy -and ((Get-RecordedField $capture 'jsonSha256' ([string])) -cne $hash -or
        (Get-RecordedField $capture 'toolSha256' ([string])) -cne $spec.capture)){throw 'Protected capture file/tool hashes differ.'}
    return $hash
}
function Assert-RecordedRollback($Report){
    $native=Get-RecordedField $Report 'nativeRollback'
    if((Get-RecordedField $native 'schema' ([int])) -ne 1 -or (Get-RecordedField $native 'vmId' ([string])) -cne $Report.vmId -or
        (Get-RecordedField $native 'runId' ([string])) -cne $Report.runId -or (Get-RecordedField $native 'instance' ([string])) -ine $Report.instance -or
        (Get-RecordedField $native 'api' ([string])) -cne 'DiRollbackDriver' -or !(Get-RecordedField $native 'testOnly' ([bool])) -or
        (Get-RecordedField $native 'productionReady' ([bool]))){throw 'Protected actual rollback API evidence is unpaired.'}
    $reboot=Get-RecordedField $native 'rebootRequired' ([bool])
    if((Get-RecordedField $native 'status' ([string])) -cne $(if($reboot){'NeedsReboot'}else{'Passed'})){throw 'Native rollback reboot outcome differs.'}
    if((Convert-RecordedUtc (Get-RecordedField $native 'utc' ([string]))) -gt (Convert-RecordedUtc $Report.utc)){
        throw 'Actual native rollback occurs after its pending parent report.'
    }
    Assert-RecordedProcess (Get-RecordedField $native 'process') 'rollback-native.log' 120 0
    $path=Get-OutputPath 'rollback-native.json';Assert-TrustedGuestAcl $path
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne (Get-RecordedField $native 'jsonSha256' ([string]))){throw 'Protected native rollback file hash differs.'}
    $actual=Read-BoundedJson $path $acceptanceRoot
    foreach($field in @('schema','vmId','runId','instance','api','testOnly','productionReady','rebootRequired','status','utc')){
        if((Get-RecordedField $actual $field) -cne (Get-RecordedField $native $field)){throw 'Actual native rollback file and parent evidence differ.'}
    }
}
function Assert-ResumePending($Report,[string]$RawHash){
    $id=[Guid]::Empty
    if((Get-RecordedField $Report 'schema' ([int])) -ne 1 -or (Get-RecordedField $Report 'vmId' ([string])) -cne $VmId.ToString('D') -or
        !(Get-RecordedField $Report 'testOnly' ([bool])) -or (Get-RecordedField $Report 'productionReady' ([bool])) -or
        (Get-RecordedField $Report 'status' ([string])) -cne 'NeedsReboot' -or !(Get-RecordedField $Report 'rebootRequired' ([bool])) -or
        (Get-RecordedField $Report 'driverMutationUncertain' ([bool])) -or (Get-RecordedField $Report 'baselineIsRollback' ([bool])) -or
        (Get-RecordedField $Report 'currentRestored' ([bool])) -or
        ![Guid]::TryParseExact((Get-RecordedField $Report 'runId' ([string])),'D',[ref]$id) -or $id -eq [Guid]::Empty){throw 'Resume requires the original protected determinate NeedsReboot run.'}
    $null=Get-PnpDeviceFilter (Get-RecordedField $Report 'instance' ([string]))
    $null=Get-RebootCheckpointName (Get-RecordedField $Report 'stage' ([string]))
    $null=Convert-RecordedUtc (Get-RecordedField $Report 'utc' ([string]))
    $legacy=(!$Report.PSObject.Properties['sourceRunnerSha256'] -and $Report -isnot [Collections.IDictionary])
    if($Report -is [Collections.IDictionary]){$legacy=!$Report.Contains('sourceRunnerSha256')}
    if($legacy){
        if($Report.runId -cne 'd430ff7c-56a1-4ae4-b729-f32ea93baac7' -or $Report.stage -cne 'upgrade' -or
            $RawHash -cne 'a99ec400c4892df17521896181bf9f753f6f08f9b3f1ff12c958b6962845886a'){
            throw 'Legacy Resume is limited to the approved exact ff1d upgrade report hash and original run.'
        }
    }else{
        if((Get-RecordedField $Report 'sourceRunnerSha256' ([string])) -cne $manifest.files.'driver-vm-version-transition.ps1' -or
            (Get-RecordedField $Report 'resumeProtocol' ([int])) -ne 1 -or (Get-RecordedField $Report 'oldVersion' ([string])) -cne '0.5.0.0' -or
            (Get-RecordedField $Report 'currentVersion' ([string])) -cne '0.5.1.0'){throw 'Resume source/protocol/version binding differs.'}
        $null=Convert-RecordedUtc (Get-RecordedField $Report 'bootUtc' ([string]))
    }
    $items=@(Get-RecordedField $Report 'stages')
    $count=switch -CaseSensitive ($Report.stage){'upgrade'{3};'rollback-native'{4};'restore'{6}}
    if($items.Count -ne $count){throw 'Resume stage prefix has missing, duplicate, or future evidence.'}
    $null=Assert-RecordedCapture $items[1] 'old-baseline' 'old' $Report $legacy
    Assert-RecordedUpdate $items[0] 'old-baseline' $items[1] $Report
    if($Report.stage -ceq 'upgrade'){
        Assert-RecordedUpdate $items[2] 'upgrade' $null $Report
        if((Get-RecordedField $Report 'apiRollbackVerified' ([bool]))){throw 'Upgrade checkpoint cannot claim a rollback.'}
    }else{
        $null=Assert-RecordedCapture $items[3] 'upgrade' 'current' $Report $false
        Assert-RecordedUpdate $items[2] 'upgrade' $items[3] $Report
        Assert-RecordedRollback $Report
        if($Report.stage -ceq 'rollback-native'){
            if((Get-RecordedField $Report 'apiRollbackVerified' ([bool])) -or !$Report.nativeRollback.rebootRequired){throw 'Native rollback checkpoint must await its reboot and capture.'}
        }else{
            $null=Assert-RecordedCapture $items[4] 'rollback' 'old' $Report $false
            Assert-RecordedUpdate $items[5] 'restore' $null $Report
            if(!(Get-RecordedField $Report 'apiRollbackVerified' ([bool]))){throw 'Final restore checkpoint lacks actual verified rollback capture.'}
        }
    }
    Assert-RecordedIdentity (Get-RecordedField $Report 'initialIdentity') 'current' $Report
    return $legacy
}
function Assert-RecordedUpdate($Entry,[string]$Stage,$Capture,$Report){
    if((Get-RecordedField $Entry 'stage' ([string])) -cne $Stage -or
        (Get-RecordedField $Entry 'operation' ([string])) -cne 'DevCon update exact hardware'){throw 'Protected update stage/order/operation differs.'}
    $completed=Get-RecordedField $Entry 'completed' ([bool])
    $exit=if($completed){0}else{1}
    Assert-RecordedProcess (Get-RecordedField $Entry 'process') ($Stage+'.log') 90 $exit
    if(!$Capture){if($completed){throw 'Resume pending update must be completed with explicit reboot exit 1.'};return}
    if(!$completed){
        $name=Get-RebootCheckpointName $Stage;$path=Get-OutputPath $name;Assert-TrustedGuestAcl $path
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -cne (Get-RecordedField $Capture 'resumeCheckpointSha256' ([string]))){throw 'Previously rebooted update capture lacks its immutable checkpoint.'}
        $pending=Read-BoundedJson $path $acceptanceRoot 1MB
        if($pending.runId -cne $Report.runId -or $pending.instance -ine $Report.instance -or $pending.stage -cne $Stage){throw 'Previously rebooted update checkpoint is foreign.'}
        $null=Assert-ResumePending $pending $hash
        if((Convert-RecordedUtc (Get-RecordedField $Capture 'resumeBootUtc' ([string]))) -le (Convert-RecordedUtc $pending.utc)){
            throw 'Previously rebooted update capture lacks a later actual boot.'
        }
    }
}
function New-RebootCheckpoint($Report,[string]$ExpectedHash){
    $source=Get-OutputPath 'version-transition.json';Assert-TrustedGuestAcl $source
    $current=Read-BoundedJson $source $acceptanceRoot 1MB
    if($Report.status -cne 'NeedsReboot' -or $current.status -cne 'NeedsReboot' -or $current.runId -cne $Report.runId -or
        $current.stage -cne $Report.stage -or $ExpectedHash -cnotmatch '\A[0-9a-f]{64}\z'){
        throw 'Checkpoint creation requires the exact validated protected pending report.'
    }
    $bytes=[IO.File]::ReadAllBytes($source)
    if($bytes.Length -lt 2 -or $bytes.Length -gt 1MB){throw 'Pending checkpoint report size differs.'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($hash -cne $ExpectedHash){throw 'Protected pending report changed before immutable checkpoint creation.'}
    $name=Get-RebootCheckpointName $Report.stage;$path=Get-OutputPath $name
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    Assert-TrustedGuestAcl $path
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash){throw 'Immutable checkpoint copy hash differs.'}
    return @{name=$name;sha256=$hash;stage=$Report.stage}
}
function Invoke-PairedNativeRollback($Result){
    $script:lastVersionSettle=$null
    $Result.stage='rollback-native';$Result.utc=[DateTime]::UtcNow.ToString('o')
    Write-Report 'version-transition.json' $Result 'VEYLO_VERSION_TRANSITION_RESULT'
    $nativePath=Get-OutputPath 'rollback-native.json'
    if(Test-Path -LiteralPath $nativePath){Remove-Item -LiteralPath $nativePath}
    $powershell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $null=Assert-CanonicalPath $powershell 'C:\Windows\System32'
    $script:driverMutationStarted=$true;$script:mutationUncertain=$true
    $process=Invoke-BoundedTool $powershell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$ownPath,
        '-VmId',$VmId.ToString('D'),'-Operation','RollbackNative','-RunId',$RunId.ToString('D')) 'rollback-native.log' 120
    $script:mutationUncertain=($process.timedOut -or $process.outputLimited)
    if($process.exitCode -ne 0 -or $process.timedOut -or $process.outputLimited){throw 'Native rollback child failed or exceeded its bounds.'}
    $native=Read-BoundedJson $nativePath $acceptanceRoot
    Assert-TrustedGuestAcl $nativePath
    $native | Add-Member -MemberType NoteProperty -Name process -Value $process
    $native | Add-Member -MemberType NoteProperty -Name jsonSha256 -Value ((Get-FileHash -LiteralPath $nativePath -Algorithm SHA256).Hash.ToLowerInvariant())
    $Result.nativeRollback=$native
    # The child's actual completion UTC necessarily follows its launch report.
    $Result.utc=[DateTime]::UtcNow.ToString('o')
    Write-Report 'version-transition.json' $Result 'VEYLO_VERSION_TRANSITION_RESULT'
    Assert-RecordedRollback $Result
    if($native.rebootRequired){$Result.rebootRequired=$true;$Result.status='NeedsReboot';return $false}
    return $true
}
function Assert-ResumeBoot($Pending,[string]$BootUtc,[bool]$Legacy){
    $boot=Convert-RecordedUtc $BootUtc;$pendingUtc=Convert-RecordedUtc $Pending.utc
    if($boot -le $pendingUtc){throw 'Resume requires an actual boot after the pending reboot report.'}
    if(!$Legacy -and $boot -le (Convert-RecordedUtc (Get-RecordedField $Pending 'bootUtc' ([string])))){
        throw 'Resume requires a changed actual boot identity.'
    }
}
function Convert-TransitionResult($Report){
    $copy=[ordered]@{}
    foreach($property in $Report.PSObject.Properties){$copy[$property.Name]=$property.Value}
    return $copy
}
function Invoke-ResumeTransition{
    $lockPath=Get-OutputPath 'transition.lock'
    $lock=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        Assert-TrustedGuestAcl $lockPath
        $path=Get-OutputPath 'version-transition.json';Assert-TrustedGuestAcl $path
        $active=Read-BoundedJson $path $acceptanceRoot 1MB
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($active.status -ceq 'NeedsReboot'){
            $legacy=Assert-ResumePending $active $hash
            $name=Get-RebootCheckpointName $active.stage;$checkpointPath=Get-OutputPath $name
            if($legacy){
                if(!(Test-Path -LiteralPath $checkpointPath)){
                    $null=New-RebootCheckpoint $active $hash
                }
                $reference=@{name=$name;sha256=$hash;stage=$active.stage}
            }else{$reference=Get-RecordedField $active 'checkpoint'}
        }elseif($active.status -ceq 'Findings' -and (Get-RecordedField $active 'resumePreflightRetryAllowed' ([bool])) -and
            (Get-RecordedField $active 'resumePhase' ([string])) -ceq 'preflight' -and
            !(Get-RecordedField $active 'driverMutationUncertain' ([bool])) -and
            (Get-RecordedField $active 'sourceRunnerSha256' ([string])) -ceq $manifest.files.'driver-vm-version-transition.ps1'){
            $reference=Get-RecordedField $active 'resumeCheckpoint'
            $name=Get-RebootCheckpointName (Get-RecordedField $reference 'stage' ([string]));$checkpointPath=Get-OutputPath $name
        }else{throw 'Resume accepts only pending reboot or the defined read-only preflight retry; no uncertain mutation recovery.'}
        if((Get-RecordedField $reference 'name' ([string])) -cne $name -or
            (Get-RecordedField $reference 'sha256' ([string])) -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Resume checkpoint reference differs.'}
        Assert-TrustedGuestAcl $checkpointPath
        $checkpointHash=(Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if($checkpointHash -cne $reference.sha256){throw 'Immutable resume checkpoint hash differs.'}
        $pending=Read-BoundedJson $checkpointPath $acceptanceRoot 1MB
        if($pending.runId -cne $active.runId -or $pending.vmId -cne $active.vmId -or $pending.instance -ine $active.instance -or
            $pending.stage -cne $reference.stage){throw 'Resume checkpoint belongs to another run, instance, or stage.'}
        $legacy=Assert-ResumePending $pending $checkpointHash
        $script:RunId=[Guid]$pending.runId
        $result=Convert-TransitionResult $pending
        # Normalize only the approved legacy evidence after pinning its raw report.
        # The immutable ff1d checkpoint remains byte-identical to its approved hash.
        if($legacy){
            $old=$result.stages[1].capture
            $old | Add-Member -MemberType NoteProperty -Name jsonSha256 -Value ((Get-FileHash -LiteralPath (Get-OutputPath 'old-baseline-capture.json') -Algorithm SHA256).Hash.ToLowerInvariant())
            $old | Add-Member -MemberType NoteProperty -Name toolSha256 -Value ((Get-VersionSpec 'old').capture)
            $result.legacySourceRunnerSha256='ff1d28016084bee3ff315529068b65edcfe04a3969abdf0c07dc9f9d6ddc0240'
        }
        $result.sourceRunnerSha256=$manifest.files.'driver-vm-version-transition.ps1';$result.resumeProtocol=1
        $result.oldVersion='0.5.0.0';$result.currentVersion='0.5.1.0'
        $result.resumeCheckpoint=$reference;$result.resumePhase='preflight';$result.resumePreflightRetryAllowed=$true
        $script:driverMutationStarted=$false;$script:mutationUncertain=$false;$script:lastVersionSettle=$null
        try{
            $bootUtc=Get-GuestBootUtc;Assert-ResumeBoot $pending $bootUtc $legacy
            $result.bootUtc=$bootUtc;$result.status='Running';$result.utc=[DateTime]::UtcNow.ToString('o')
            Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
            $device=Assert-OneSesDevice
            if($device.DeviceID -ine $result.instance){throw 'Resume original exact instance differs.'}
            foreach($version in @('old','current')){
                $cert=Read-PublicCertificate $version
                try{foreach($store in @('Root','TrustedPublisher')){if((Get-VersionSpec $version).thumb -cnotin @(Get-CertificateStoreInventory $store)){throw 'Resume pinned certificates are not already trusted.'}}}
                finally{$cert.Dispose()}
            }
            $phase=if($pending.stage -ceq 'rollback-native'){'rollback'}else{$pending.stage}
            $version=if($phase -ceq 'rollback'){'old'}else{'current'}
            $null=Wait-VersionIdentity $version ([string]$result.instance)
            $result.rebootRequired=$false;$result.resumePhase='capture';$result.resumePreflightRetryAllowed=$false
            $result.stage=if($phase -ceq 'rollback'){'rollback-native'}else{$phase};$result.utc=[DateTime]::UtcNow.ToString('o')
            Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
            $capture=Invoke-VersionCapture $phase $version ([string]$result.instance)
            $result.stages+=@{stage=$phase;expectedVersion=(Get-VersionSpec $version).version;status='Passed';capture=$capture;
                resumeCheckpointSha256=$checkpointHash;resumeBootUtc=$bootUtc}
            if($phase -ceq 'rollback'){$result.apiRollbackVerified=$true}
            if($phase -ceq 'restore'){$result.currentRestored=$true}
            $result.resumePhase='continuation'
            foreach($next in @($(if($phase -ceq 'upgrade'){'rollback'}),$(if($phase -cne 'restore'){'restore'})) | Where-Object {$_}){
                $script:lastVersionSettle=$null;$result.stage=$next;$result.utc=[DateTime]::UtcNow.ToString('o')
                Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
                if($next -ceq 'rollback'){
                    if(!(Invoke-PairedNativeRollback $result)){break};$name='old'
                }else{
                    $name='current';$process=Invoke-FixedUpdate 'current' 'restore.log'
                    $completed=Assert-UpdateCompleted $process
                    $result.stages+=@{stage='restore';operation='DevCon update exact hardware';process=$process;completed=$completed}
                    if(!$completed){$result.rebootRequired=$true;$result.status='NeedsReboot';break}
                }
                $capture=Invoke-VersionCapture $next $name ([string]$result.instance)
                $result.stages+=@{stage=$next;expectedVersion=(Get-VersionSpec $name).version;status='Passed';capture=$capture}
                if($next -ceq 'rollback'){$result.apiRollbackVerified=$true}
                if($next -ceq 'restore'){$result.currentRestored=$true}
            }
            if($result.status -ceq 'Running'){
                $result.utc=[DateTime]::UtcNow.ToString('o');$result.driverMutationUncertain=$script:mutationUncertain
                Assert-FullTransitionEvidence $result
                $result.stage='complete';$result.status='Passed';$result.resumePhase='complete'
            }
        }catch{
            $result.status='Findings';$result.error=$_.Exception.Message
            if($_.Exception.Data.Contains('VeyloIdentityChildUncertain')){$result.resumePreflightRetryAllowed=$false}
            if($script:lastVersionSettle){$result.failedSettle=$script:lastVersionSettle}
            $result.restoreSkipped='Resume preserves its checkpoint and performs no automatic recovery after a failed preflight, capture, or continuation.'
        }
        $result.driverMutationUncertain=$script:mutationUncertain;$result.utc=[DateTime]::UtcNow.ToString('o')
        if($result.status -ceq 'NeedsReboot'){
            Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
            $result.checkpoint=New-RebootCheckpoint $result ((Get-FileHash -LiteralPath (Get-OutputPath 'version-transition.json') -Algorithm SHA256).Hash.ToLowerInvariant())
        }
        Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
        if($result.status -ceq 'NeedsReboot'){return 2};if($result.status -cne 'Passed'){return 1};return 0
    }finally{$lock.Dispose()}
}
function Assert-FullTransitionEvidence($Report){
    if(!(Get-RecordedField $Report 'apiRollbackVerified' ([bool])) -or !(Get-RecordedField $Report 'currentRestored' ([bool])) -or
        (Get-RecordedField $Report 'rebootRequired' ([bool])) -or (Get-RecordedField $Report 'driverMutationUncertain' ([bool]))){throw 'Incomplete transition evidence.'}
    $items=@(Get-RecordedField $Report 'stages')
    if($items.Count -ne 7){throw 'Passed requires exactly the four ordered actual phase captures and three fixed updates.'}
    foreach($entry in @(@(0,1,'old-baseline','old'),@(2,3,'upgrade','current'),@(5,6,'restore','current'))){
        $null=Assert-RecordedCapture $items[$entry[1]] $entry[2] $entry[3] $Report $false
        Assert-RecordedUpdate $items[$entry[0]] $entry[2] $items[$entry[1]] $Report
    }
    $null=Assert-RecordedCapture $items[4] 'rollback' 'old' $Report $false
    Assert-RecordedRollback $Report
    if($Report.nativeRollback.rebootRequired){
        $path=Get-OutputPath 'resume-rollback-checkpoint.json';Assert-TrustedGuestAcl $path
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -cne (Get-RecordedField $items[4] 'resumeCheckpointSha256' ([string]))){throw 'Actual rebooting rollback requires its preserved checkpoint.'}
        $pending=Read-BoundedJson $path $acceptanceRoot 1MB
        $null=Assert-ResumePending $pending $hash
        if($pending.runId -cne $Report.runId -or (Convert-RecordedUtc (Get-RecordedField $items[4] 'resumeBootUtc' ([string]))) -le (Convert-RecordedUtc $pending.utc)){
            throw 'Actual rebooting rollback capture is unpaired or precedes its new boot.'
        }
    }
}
function Initialize-NativeIdentity{
    if('VeyloLab.InstalledIdentity' -as [type]){return}
    # SDK devpkey.h: a8b865dd-2e3d-4094-ad97-e593a70c75d6,
    # DriverVersion pid 3; DriverInfPath pid 5. Both DEVPROP_TYPE_STRING (0x12).
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
namespace VeyloLab {
    public static class InstalledIdentity {
        [StructLayout(LayoutKind.Sequential)]
        public struct DeviceInfo { public uint cbSize; public Guid ClassGuid; public uint DevInst; public UIntPtr Reserved; }
        [StructLayout(LayoutKind.Sequential)]
        public struct PropertyKey { public Guid fmtid; public uint pid; }
        public sealed class Result { public string Version; public string InfName; }
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", ExactSpelling=true, SetLastError=true)]
        private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr parent);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", EntryPoint="SetupDiOpenDeviceInfoW", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiOpenDeviceInfo(IntPtr set, string instance, IntPtr parent, uint flags, ref DeviceInfo info);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", EntryPoint="SetupDiGetDevicePropertyW", ExactSpelling=true, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiGetDeviceProperty(IntPtr set, ref DeviceInfo info, ref PropertyKey key,
            out uint type, [Out] byte[] buffer, uint bufferSize, out uint requiredSize, uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", ExactSpelling=true, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        // Pure parser is public for inert fixture tests; it performs no native IO.
        public static string DecodeString(byte[] buffer, uint size, uint type) {
            if (buffer == null || type != 0x12 || size < 4 || size > 1024 || size > buffer.Length || (size & 1) != 0)
                throw new InvalidOperationException("Native property type or bounded UTF-16 size differs.");
            int count = checked((int)size);
            if (buffer[count-2] != 0 || buffer[count-1] != 0)
                throw new InvalidOperationException("Native property is not terminated.");
            string value = new UnicodeEncoding(false, false, true).GetString(buffer, 0, count-2);
            if (value.Length == 0 || value.IndexOf('\0') >= 0)
                throw new InvalidOperationException("Empty or multi-string native property rejected.");
            return value;
        }
        public static void ValidateValues(string version, string inf) {
            if (version == null || !Regex.IsMatch(version, @"\A[0-9]{1,5}(?:\.[0-9]{1,5}){3}\z", RegexOptions.CultureInvariant))
                throw new InvalidOperationException("Native driver version format differs.");
            foreach (string part in version.Split('.'))
                if (UInt32.Parse(part, System.Globalization.CultureInfo.InvariantCulture) > 65535)
                    throw new InvalidOperationException("Native driver version component exceeds WORD range.");
            if (inf == null || !Regex.IsMatch(inf, @"\Aoem[0-9]{1,4}\.inf\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                throw new InvalidOperationException("Native installed INF is not a bounded published basename.");
        }
        private static string ReadProperty(IntPtr set, ref DeviceInfo info, uint pid) {
            PropertyKey key = new PropertyKey { fmtid = new Guid("a8b865dd-2e3d-4094-ad97-e593a70c75d6"), pid = pid };
            byte[] buffer = new byte[1024];
            uint type, size;
            if (!SetupDiGetDeviceProperty(set, ref info, ref key, out type, buffer, (uint)buffer.Length, out size, 0))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Exact installed driver property read failed.");
            return DecodeString(buffer, size, type);
        }
        public static Result Read(string instance) {
            if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(DeviceInfo)) != 32 || Marshal.SizeOf(typeof(PropertyKey)) != 20 ||
                Marshal.OffsetOf(typeof(PropertyKey), "pid").ToInt32() != 16 || Marshal.OffsetOf(typeof(DeviceInfo), "Reserved").ToInt32() != 24)
                throw new InvalidOperationException("Native x64 device/property ABI mismatch.");
            if (instance == null || !Regex.IsMatch(instance, @"\AROOT\\(?:MEDIA|SES_MICROPHONE)\\[0-9]{4}\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                throw new ArgumentException("Exact root audio instance required.");
            Guid media = new Guid("4d36e96c-e325-11ce-bfc1-08002be10318");
            IntPtr set = SetupDiCreateDeviceInfoList(ref media, IntPtr.Zero);
            if (set == new IntPtr(-1) || set == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Create device info list failed.");
            try {
                DeviceInfo info = new DeviceInfo { cbSize = 32 };
                if (!SetupDiOpenDeviceInfo(set, instance, IntPtr.Zero, 0, ref info))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Open exact device instance failed.");
                if (info.ClassGuid != media) throw new InvalidOperationException("Exact device MEDIA class differs.");
                string version = ReadProperty(set, ref info, 3);
                string inf = ReadProperty(set, ref info, 5);
                ValidateValues(version, inf);
                return new Result { Version = version, InfName = inf };
            } finally {
                if (!SetupDiDestroyDeviceInfoList(set))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Destroy read-only device info list failed.");
            }
        }
    }
}
'@
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
if($Operation -ceq 'IdentityNative'){
    $parentPath=Get-OutputPath 'version-transition.json'
    Assert-TrustedGuestAcl $parentPath
    $parent=Read-BoundedJson $parentPath $acceptanceRoot 1MB
    $stamp=Assert-IdentityRequest $parent $RequestId ([string]$parent.instance)
    Assert-IdentityParentLock
    $device=Assert-OneSesDevice
    if($device.DeviceID -ine $parent.instance){throw 'Native identity original device differs.'}
    Initialize-NativeIdentity
    $installed=[VeyloLab.InstalledIdentity]::Read([string]$parent.instance)
    # Re-check the pending request after potentially slow native calls; never
    # publish a late or replaced request as a successful current identity.
    $after=Read-BoundedJson $parentPath $acceptanceRoot 1MB
    $null=Assert-IdentityRequest $after $RequestId ([string]$parent.instance)
    Assert-IdentityParentLock
    Write-Report 'identity-native.json' ([ordered]@{schema=1;vmId=$VmId.ToString('D');runId=$RunId.ToString('D');
        requestId=$RequestId.ToString('D');instance=[string]$parent.instance;api='SetupDiGetDevicePropertyW';
        nativeVersion=$installed.Version;nativeInfName=$installed.InfName;utc=[DateTimeOffset]::UtcNow.ToString('o');
        status='Passed';testOnly=$true;productionReady=$false}) 'VEYLO_VERSION_IDENTITY_NATIVE'
    exit 0
}
if($RequestId -ne [Guid]::Empty){throw 'Request identity is valid only for the read-only identity child.'}
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
if($Operation -ceq 'Resume'){exit (Invoke-ResumeTransition)}
$lockPath=Get-OutputPath 'transition.lock'
$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    Assert-TrustedGuestAcl $lockPath
    foreach($checkpointName in @('resume-upgrade-checkpoint.json','resume-rollback-checkpoint.json','resume-restore-checkpoint.json')){
        if(Test-Path -LiteralPath (Get-OutputPath $checkpointName)){throw 'A preserved checkpoint forbids starting a replacement run; inspect or explicitly resume the original run.'}
    }
    $previousPath=Get-OutputPath 'version-transition.json'
    if(Test-Path -LiteralPath $previousPath){
        $previous=Read-BoundedJson $previousPath $acceptanceRoot 1MB
        if($previous.status -ceq 'NeedsReboot'){throw 'The protected pending reboot run requires explicit Resume; it must not restart the historical baseline.'}
    }
    $RunId=[Guid]::NewGuid()
    $script:driverMutationStarted=$false;$script:mutationUncertain=$false;$script:lastVersionSettle=$null;$restoreAttempted=$false
    $result=[ordered]@{schema=1;vmId=$VmId.ToString('D');runId=$RunId.ToString('D');testOnly=$true;
        productionReady=$false;status='Running';stage='preflight';utc=[DateTime]::UtcNow.ToString('o');
        rebootRequired=$false;baselineIsRollback=$false;apiRollbackVerified=$false;currentRestored=$false;
        driverMutationUncertain=$false;certificateStores=@();stages=@();bootUtc=$null;resumeProtocol=1;
        sourceRunnerSha256=$manifest.files.'driver-vm-version-transition.ps1';oldVersion='0.5.0.0';currentVersion='0.5.1.0'}
    # Immediately invalidate any stale Passed summary, before certificate/driver changes.
    Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
    try{
        $result.bootUtc=Get-GuestBootUtc
        $device=Assert-OneSesDevice;$result.instance=[string]$device.DeviceID
        Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
        $result.initialIdentity=Read-VersionIdentity 'current' ([string]$result.instance)
        $currentCertificate=Read-PublicCertificate 'current'
        $currentCertificate.Dispose()
        Add-OldPublicCertificate $result
        foreach($stage in @('old-baseline','upgrade','rollback','restore')){
            $script:lastVersionSettle=$null
            $result.stage=$stage;$result.utc=[DateTime]::UtcNow.ToString('o')
            Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
            if($stage -ceq 'rollback'){
                if(!(Invoke-PairedNativeRollback $result)){break}
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
            $result.utc=[DateTime]::UtcNow.ToString('o');$result.driverMutationUncertain=$script:mutationUncertain
            Assert-FullTransitionEvidence $result
            $result.stage='complete';$result.status='Passed'
        }
    }catch{
        $result.status='Findings';$result.error=$_.Exception.Message
        if($script:lastVersionSettle){$result.failedSettle=$script:lastVersionSettle}
        # A bounded child that was killed may have an in-flight kernel operation.
        # Do not run another driver mutation or claim restoration in that state.
        if($script:driverMutationStarted -and !$script:mutationUncertain -and !$result.rebootRequired -and !$restoreAttempted){
            $result.stage='failure-restore';$result.utc=[DateTime]::UtcNow.ToString('o')
            Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
            try{
                $restoreProcess=Invoke-FixedUpdate 'current' 'restore.log'
                $result.failureRestore=@{status='Running';process=$restoreProcess;completed=$false;capture=$null;settle=$null;error=$null}
                $completed=Assert-UpdateCompleted $restoreProcess
                $result.failureRestore.completed=$completed
                if(!$completed){$result.rebootRequired=$true;$result.status='NeedsReboot';$result.failureRestore.status='NeedsReboot'}
                else{
                    $restoreCapture=Invoke-VersionCapture 'restore' 'current' ([string]$result.instance)
                    $result.currentRestored=$true
                    $result.failureRestore.status='Passed';$result.failureRestore.capture=$restoreCapture
                    $result.failureRestore.settle=$restoreCapture.settle
                }
            }catch{
                if(!$result.Contains('failureRestore')){$result.failureRestore=@{status='Findings';process=$null;completed=$false;capture=$null;settle=$null;error=$null}}
                $result.failureRestore.status='Findings';$result.failureRestore.error=$_.Exception.Message
                if($script:lastVersionSettle){$result.failureRestore.settle=$script:lastVersionSettle}
            }
        }
        elseif($script:driverMutationStarted){$result.restoreSkipped='Reboot, uncertain in-flight mutation, or already attempted final restoration requires explicit guest inspection.'}
    }
    $result.driverMutationUncertain=$script:mutationUncertain
    $result.utc=[DateTime]::UtcNow.ToString('o')
    if($result.status -ceq 'NeedsReboot' -and $result.stage -cin @('upgrade','rollback-native','restore')){
        Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
        $result.checkpoint=New-RebootCheckpoint $result ((Get-FileHash -LiteralPath (Get-OutputPath 'version-transition.json') -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    Write-Report 'version-transition.json' $result 'VEYLO_VERSION_TRANSITION_RESULT'
    if($result.status -ceq 'NeedsReboot'){exit 2}
    if($result.status -cne 'Passed'){exit 1}
}finally{$lock.Dispose()}
