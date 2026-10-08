$ErrorActionPreference='Stop'
$driverSourceRoot=Split-Path $PSScriptRoot -Parent
$driverPayloadNames=@('SesMicrophone.inf','SesMicrophone.sys','SesMicrophone.cat','SYSVAD-LICENSE')

function Get-DriverContract {
    $inf=Get-Content -LiteralPath (Join-Path $driverSourceRoot 'driver/SesMicrophone.inf') -Raw
    $abi=Get-Content -LiteralPath (Join-Path $driverSourceRoot 'native/include/ses.h') -Raw
    $protocol=Get-Content -LiteralPath (Join-Path $driverSourceRoot 'driver/shared/ses_driver_protocol.h') -Raw
    if($inf -notmatch '(?m)^DriverVer=\d{2}/\d{2}/\d{4},(\d+\.\d+\.\d+\.\d+)\s*$'){throw 'Invalid driver version'}
    $version=$Matches[1]
    if($abi -notmatch '#define SES_ABI_VERSION (\d+)u'){throw 'Missing native ABI'}
    $abiValue=[int]$Matches[1]
    if($protocol -notmatch '#define SES_DRIVER_PROTOCOL (\d+)u'){throw 'Missing driver protocol'}
    [xml]$app=Get-Content -LiteralPath (Join-Path $driverSourceRoot 'app/Ses.Desktop/Ses.Desktop.csproj')
    return @{driverVersion=$version;abi=$abiValue;protocol=[int]$Matches[1];appVersion=[string]$app.Project.PropertyGroup.Version}
}

function Get-DriverPayloadHashes([string]$Directory) {
    $folder=Get-Item -LiteralPath $Directory
    if(!$folder.PSIsContainer -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid driver package directory'}
    $hashes=[ordered]@{}
    foreach($name in $driverPayloadNames){
        $file=Get-Item -LiteralPath (Join-Path $Directory $name)
        if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -lt 1 -or $file.Length -gt 16MB){throw ('Invalid driver payload: '+$name)}
        $hashes[$name]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if($hashes['SesMicrophone.inf'] -ne (Get-FileHash -LiteralPath (Join-Path $driverSourceRoot 'driver/SesMicrophone.inf') -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Driver INF does not match the current source'}
    return $hashes
}

function New-DevelopmentDriverManifest([string]$Directory) {
    $contract=Get-DriverContract
    $kit=Get-Content -LiteralPath (Join-Path $driverSourceRoot 'driver/ewdk.lock.json') -Raw | ConvertFrom-Json
    $upstream=Get-Content -LiteralPath (Join-Path $driverSourceRoot 'driver/upstream.lock.json') -Raw | ConvertFrom-Json
    $manifest=[ordered]@{schema=2;driverVersion=$contract.driverVersion;appVersion=$contract.appVersion;abi=$contract.abi;protocol=$contract.protocol;signed=$false;dailyUseReady=$false;kit=$kit.kit;kitSha256=$kit.sha256;sysvadCommit=$upstream.commit;files=(Get-DriverPayloadHashes $Directory)}
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory 'development-manifest.json') -Encoding utf8
}

function Assert-DevelopmentDriverPackage([string]$Directory) {
    $path=Join-Path $Directory 'development-manifest.json'
    $file=Get-Item -LiteralPath $path
    if($file.Length -gt 64KB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid driver manifest'}
    $manifest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $contract=Get-DriverContract
    if($manifest.schema -ne 2 -or $manifest.signed -ne $false -or $manifest.dailyUseReady -ne $false -or
       $manifest.abi -ne $contract.abi -or $manifest.protocol -ne $contract.protocol -or
       $manifest.driverVersion -ne $contract.driverVersion -or $manifest.appVersion -ne $contract.appVersion){throw 'Stale or incompatible development manifest'}
    $properties=@($manifest.files.PSObject.Properties)
    if($properties.Count -ne $driverPayloadNames.Count){throw 'Unexpected manifest payload'}
    foreach($property in $properties){if($property.Name -cnotin $driverPayloadNames -or $property.Value -notmatch '^[0-9a-f]{64}$'){throw 'Invalid manifest payload entry'}}
    $hashes=Get-DriverPayloadHashes $Directory
    foreach($name in $driverPayloadNames){if($manifest.files.$name -cne $hashes[$name]){throw ('Driver checksum mismatch: '+$name)}}
    return $manifest
}
