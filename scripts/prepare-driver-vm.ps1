# Creates only a new, owned virtual disk and seed. Never configures the host OS.
param([switch]$AcceptEvaluationLicense,[string]$TestSignedPackage,[ValidateSet('whpx','tcg')][string]$Accelerator='whpx',[switch]$Start,[string]$EwdkRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'driver-signing.ps1')
if(!$AcceptEvaluationLicense){throw 'Explicit -AcceptEvaluationLicense is required for the Microsoft evaluation guest only'}
$toolRoot=Join-Path $labSigningRoot '.tools/driver-lab'
$iso=Join-Path $toolRoot 'Windows11-IoT-LTSC-2024-eval.iso'
$lock=Get-Content -LiteralPath (Join-Path $labSigningRoot 'driver/lab.lock.json') -Raw | ConvertFrom-Json
foreach($item in @(@{path=$iso;hash=$lock.windows.sha256},@{path=(Join-Path $toolRoot 'qemu/qemu-system-x86_64.exe');hash=$lock.qemu.systemSha256},@{path=(Join-Path $toolRoot 'qemu/qemu-img.exe');hash=$lock.qemu.imageSha256})){
    Assert-LabPath $item.path $toolRoot | Out-Null
    if((Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.hash){throw 'Pinned VM input checksum mismatch'}
}
Assert-TestSignedLabManifest $TestSignedPackage | Out-Null
if(!$EwdkRoot){
    $image=Get-DiskImage -ImagePath (Join-Path $labSigningRoot '.tools/ewdk/EWDK_26100.iso')
    $volumes=@($image | Get-Volume)
    if(!$image.Attached -or $volumes.Count -ne 1 -or !$volumes[0].DriveLetter){throw 'Mount the pinned EWDK read-only before preparing the guest'}
    $EwdkRoot=$volumes[0].DriveLetter+':\'
}
Get-LabSigningTools $EwdkRoot | Out-Null
$devcon=Join-Path $EwdkRoot 'Program Files/Windows Kits/10/Tools/10.0.26100.0/x64/devcon.exe'
if((Get-FileHash -LiteralPath $devcon -Algorithm SHA256).Hash.ToLowerInvariant() -cne $lock.devconSha256){throw 'Pinned WDK device tool mismatch'}
$volume=Get-PSDrive -Name ([IO.Path]::GetPathRoot($labSigningRoot).TrimEnd(':\'))
if($volume.Free -lt 40GB){throw 'At least 40GB free workspace space is required for the sparse lab disk'}
$vm=Join-Path $toolRoot ('vm-'+[Guid]::NewGuid().ToString('N'))
Assert-LabPath $vm $toolRoot -MayNotExist | Out-Null
# Reuse the owner/SYSTEM-only ACL implementation with a private artifacts seed.
$seed=New-LabPrivateDirectory (Join-Path $labSigningRoot ('artifacts/driver-test-signing/vm-seed-'+[Guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $vm | Out-Null
Set-Acl -LiteralPath $vm -AclObject (Get-Acl -LiteralPath $seed)
$id=[Guid]::NewGuid().ToString()
$disk=Join-Path $vm 'windows.qcow2'
& (Join-Path $toolRoot 'qemu/qemu-img.exe') create -f qcow2 $disk 64G
if($LASTEXITCODE -ne 0){throw 'Owned virtual disk creation failed'}
foreach($name in ($labPublicNames+@('test-signing-manifest.json'))){Copy-Item -LiteralPath (Join-Path $TestSignedPackage $name) -Destination $seed}
Copy-Item -LiteralPath $devcon -Destination (Join-Path $seed 'devcon.exe')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'driver-vm-guest.ps1') -Destination (Join-Path $seed 'guest.ps1')
$seedHashes=[ordered]@{};foreach($file in Get-ChildItem -LiteralPath $seed -File){$seedHashes[$file.Name]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
@{schema=1;id=$id;files=$seedHashes;testOnly=$true} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $seed 'veylo-lab-seed.json') -Encoding utf8
$password='V!'+[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))+'a'
# Disk 0 below is ONLY the newly created QCOW2 attached by our fixed QEMU launch.
# The generated XML contains a transient guest credential and stays private/ignored.
@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
 <settings pass="windowsPE">
  <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>
  <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <DiskConfiguration><Disk xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk><CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions><ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>VEYLO-LAB</Label><Letter>C</Letter><Active>true</Active></ModifyPartition></ModifyPartitions></Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration>
   <ImageInstall><OSImage><InstallFrom><MetaData xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>1</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
   <UserData><AcceptEula>true</AcceptEula><FullName>Veylo Lab</FullName><Organization>Local driver evaluation</Organization></UserData>
  </component>
 </settings>
 <settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>VEYLO-LAB</ComputerName><TimeZone>UTC</TimeZone></component></settings>
 <settings pass="oobeSystem">
  <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
   <UserAccounts><LocalAccounts><LocalAccount xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add"><Name>VeyloLab</Name><Group>Administrators</Group><Password><Value>$password</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
   <AutoLogon><Username>VeyloLab</Username><Password><Value>$password</Value><PlainText>true</PlainText></Password><Enabled>true</Enabled><LogonCount>1</LogonCount></AutoLogon>
   <FirstLogonCommands><SynchronousCommand xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" wcm:action="add"><Order>1</Order><Description>Isolated Veylo driver lab</Description><CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$s=Get-PSDrive -PSProvider FileSystem | Where-Object {Test-Path (Join-Path `$_.Root 'veylo-lab-seed.json')} | Select-Object -First 1; if(`$s){&amp; (Join-Path `$s.Root 'guest.ps1')}"</CommandLine></SynchronousCommand></FirstLogonCommands>
  </component>
 </settings>
</unattend>
"@ | Set-Content -LiteralPath (Join-Path $seed 'autounattend.xml') -Encoding utf8
$password=$null
[xml](Get-Content -LiteralPath (Join-Path $seed 'autounattend.xml') -Raw) | Out-Null
$metadata=@{schema=1;id=$id;ownedBy='Veylo isolated driver lab';disk=$disk;seed=$seed;iso=$iso;accelerator=$Accelerator;createdUtc=[DateTime]::UtcNow.ToString('O');hostSecurityChanged=$false;installed=$false;kernelTestsPassed=$false}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $vm 'vm.json') -Encoding utf8
Write-Output $vm
if($Start){& (Join-Path $PSScriptRoot 'start-driver-vm.ps1') -VmDirectory $vm}
