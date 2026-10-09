# NEVER run this script on the host. It changes ONLY the identity-checked guest.
$ErrorActionPreference='Stop'
$system=Get-CimInstance Win32_ComputerSystem
$product=Get-CimInstance Win32_ComputerSystemProduct
if($system.Manufacturer -cne 'QEMU' -or $system.Model -cne 'VeyloDriverLab' -or $env:COMPUTERNAME -cne 'VEYLO-LAB'){throw 'This is not the isolated Veylo Windows guest'}
function Lab-Serial([string]$Message){
    try{$port=[IO.Ports.SerialPort]::new('COM1',115200);$port.Open();try{$port.WriteLine($Message)}finally{$port.Close();$port.Dispose()}}catch{}
}
$local='C:/VeyloLab'
$allowed=@('SesMicrophone.inf','SesMicrophone.sys','SesMicrophone.cat','SYSVAD-LICENSE','lab-test.cer','ses_driver_lab_tests.exe','ses_driver_capture_lab_tests.exe','DRIVER.md','DRIVER-LAB.md','LICENSE','README-TEST-SIGNED.txt','test-signing-manifest.json','devcon.exe','guest.ps1')
if(!(Test-Path -LiteralPath (Join-Path $local 'veylo-lab-seed.json'))){
    $drives=@(Get-PSDrive -PSProvider FileSystem | Where-Object {Test-Path -LiteralPath (Join-Path $_.Root 'veylo-lab-seed.json')})
    if($drives.Count -ne 1){throw 'Exactly one owned lab seed is required'}
    $seed=$drives[0].Root;$identity=Get-Content -LiteralPath (Join-Path $seed 'veylo-lab-seed.json') -Raw | ConvertFrom-Json
    if($identity.schema -ne 1 -or $identity.testOnly -ne $true -or $identity.id -ine $product.UUID){throw 'Guest hardware UUID differs from seed'}
    if(@($identity.files.PSObject.Properties).Count -ne $allowed.Count){throw 'Invalid seed inventory'}
    foreach($entry in $identity.files.PSObject.Properties){
        if($entry.Name -cnotin $allowed -or $entry.Value -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid seed payload'}
        $file=Join-Path $seed $entry.Name;$info=Get-Item -LiteralPath $file
        if($info.Length -gt 16MB -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){throw 'Seed hash/type/size mismatch'}
    }
    if(Test-Path -LiteralPath $local){throw 'Refusing to overwrite an existing guest lab directory'}
    New-Item -ItemType Directory -Path $local | Out-Null
    foreach($name in $allowed){Copy-Item -LiteralPath (Join-Path $seed $name) -Destination (Join-Path $local $name)}
    Copy-Item -LiteralPath (Join-Path $seed 'veylo-lab-seed.json') -Destination $local
}
$identity=Get-Content -LiteralPath (Join-Path $local 'veylo-lab-seed.json') -Raw | ConvertFrom-Json
if($identity.schema -ne 1 -or $identity.testOnly -ne $true -or $identity.id -ine $product.UUID -or @($identity.files.PSObject.Properties).Count -ne $allowed.Count){throw 'Local guest identity mismatch'}
foreach($entry in $identity.files.PSObject.Properties){
    if($entry.Name -cnotin $allowed -or $entry.Value -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid local guest inventory'}
    $file=Join-Path $local $entry.Name;$info=Get-Item -LiteralPath $file
    if($info.PSIsContainer -or $info.Length -gt 16MB -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){throw 'Local guest payload changed'}
}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    Lab-Serial 'VEYLO_LAB: guest administrator consent required'
    # Identity/hash checks precede guest-only UAC; never request host elevation.
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','C:\VeyloLab\guest.ps1') | Out-Null
    return
}
if(!(Test-Path -LiteralPath (Join-Path $local 'prepared.flag'))){
    # The startup task executes as SYSTEM. Keep its code and manifest writable
    # only by guest administrators/SYSTEM, including file ownership.
    $admins=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544');$systemSid=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $directoryAcl=[Security.AccessControl.DirectorySecurity]::new();$directoryAcl.SetOwner($admins);$directoryAcl.SetAccessRuleProtection($true,$false)
    foreach($sid in @($admins,$systemSid)){$directoryAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))}
    Set-Acl -LiteralPath $local -AclObject $directoryAcl
    foreach($name in ($allowed+@('veylo-lab-seed.json'))){
        $fileAcl=[Security.AccessControl.FileSecurity]::new();$fileAcl.SetOwner($admins);$fileAcl.SetAccessRuleProtection($true,$false)
        foreach($sid in @($admins,$systemSid)){$fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))}
        Set-Acl -LiteralPath (Join-Path $local $name) -AclObject $fileAcl
    }
    $manifest=Get-Content -LiteralPath (Join-Path $local 'test-signing-manifest.json') -Raw | ConvertFrom-Json
    if($manifest.testOnly -ne $true -or $manifest.microsoftProductionSigned -ne $false -or $manifest.dailyUseReady -ne $false){throw 'Not a lab test certificate package'}
    $cer=Join-Path $local 'lab-test.cer'
    if((Get-FileHash -LiteralPath $cer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.certificateSha256){throw 'Certificate digest mismatch'}
    # Allowed only after QEMU hardware, UUID and owned seed checks above.
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:/LocalMachine/Root | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:/LocalMachine/TrustedPublisher | Out-Null
    & bcdedit.exe /set testsigning on | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Guest test signing could not be enabled'}
    Set-Service AudioEndpointBuilder -StartupType Automatic;Set-Service Audiosrv -StartupType Automatic
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\VeyloLab\guest.ps1'
    $trigger=New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName 'VeyloIsolatedDriverLab' -Action $action -Trigger $trigger -User SYSTEM -RunLevel Highest | Out-Null
    Set-Content -LiteralPath (Join-Path $local 'prepared.flag') -Value $identity.id
    Lab-Serial 'VEYLO_LAB: guest prepared; shutting down for clean pre-driver snapshot'
    Stop-Computer -Force
    return
}
if(Test-Path -LiteralPath (Join-Path $local 'result.json')){return}
try{
    Start-Sleep -Seconds 20
    Start-Service AudioEndpointBuilder;Start-Service Audiosrv
    & (Join-Path $local 'devcon.exe') install (Join-Path $local 'SesMicrophone.inf') 'ROOT\SES_MICROPHONE' *> (Join-Path $local 'install.log')
    $installExit=$LASTEXITCODE;if($installExit -notin @(0,1)){throw 'Guest driver install failed'}
    if($installExit -eq 1){throw 'Guest install requires another reboot; manual lab follow-up required'}
    Start-Sleep -Seconds 20
    & (Join-Path $local 'ses_driver_lab_tests.exe') --isolated-lab *> (Join-Path $local 'ioctl.log');$ioctlExit=$LASTEXITCODE
    & (Join-Path $local 'ses_driver_capture_lab_tests.exe') --isolated-lab --json-report (Join-Path $local 'capture.json') *> (Join-Path $local 'capture.log');$captureExit=$LASTEXITCODE
    $result=@{schema=1;guestBuild=[Environment]::OSVersion.Version.ToString();installExit=$installExit;ioctlExit=$ioctlExit;captureExit=$captureExit;passed=($ioctlExit -eq 0 -and $captureExit -eq 0);productionReady=$false;hvciVerifier='not-run'}
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $local 'result.json') -Encoding utf8
    Lab-Serial ('VEYLO_LAB_RESULT: '+($result | ConvertTo-Json -Compress))
    foreach($name in @('install.log','ioctl.log','capture.log','capture.json')){Lab-Serial ('VEYLO_LAB_FILE: '+$name);foreach($line in Get-Content -LiteralPath (Join-Path $local $name) -ErrorAction SilentlyContinue){Lab-Serial $line}}
}catch{
    Lab-Serial ('VEYLO_LAB_FAILURE: '+$_.Exception.Message)
    throw
}
