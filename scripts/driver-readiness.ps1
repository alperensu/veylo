# Read-only preflight. Does not configure Windows, enable test signing or install drivers.
param([string]$OutFile)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'driver-package.ps1')
$os=Get-CimInstance Win32_OperatingSystem
$system=Get-CimInstance Win32_ComputerSystem
$disk=Get-PSDrive -Name ([IO.Path]::GetPathRoot($root).TrimEnd(':\'))
$packet=Join-Path $root 'build/driver/package'
$packageState='missing';$packageError='';$manifest=$null
if(Test-Path -LiteralPath (Join-Path $packet 'development-manifest.json')){
    try{$manifest=Assert-DevelopmentDriverPackage $packet;$packageState='unsigned-development'}catch{$packageState='invalid-or-stale';$packageError=$_.Exception.Message}
}
$report=[ordered]@{
    schema=1;osBuild=$os.BuildNumber;osCaption=$os.Caption;hypervisorPresent=[bool]$system.HypervisorPresent
    workspaceFreeBytes=[long]$disk.Free;hyperVCommandsAvailable=[bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    pinnedEwdkPresent=(Test-Path -LiteralPath (Join-Path $root '.tools/ewdk/EWDK_26100.iso'))
    driverPackageState=$packageState;driverPackageError=$packageError;contract=(Get-DriverContract)
    isolatedLabValidated=$false;productionSigningValidated=$false;dailyDriverReady=$false
    pending=@('Isolated Windows target with snapshot and kernel test evidence','Microsoft Hardware Dev Center/EV signing prerequisites','Microsoft-signed package verification','HVCI, Driver Verifier, lifecycle and receiving-application tests')
    currentRoute='Retain VB-CABLE until signed driver and acceptance are verified'
}
$json=$report | ConvertTo-Json -Depth 5
if($OutFile){$parent=Split-Path ([IO.Path]::GetFullPath($OutFile));New-Item -ItemType Directory -Force $parent | Out-Null;$json | Set-Content -LiteralPath $OutFile -Encoding utf8}
Write-Output $json
