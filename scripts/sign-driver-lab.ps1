param([string]$EwdkRoot,[switch]$ValidateOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'driver-signing.ps1')
$inputPackage=Join-Path $labSigningRoot 'build/driver/package'
$source=Assert-TestSigningInput $inputPackage
if($ValidateOnly){Write-Output 'PASS fixed unsigned payload and current source/kit manifest; no files signed or certificates created';return}
$tools=Get-LabSigningTools $EwdkRoot
$dotnet=Join-Path $labSigningRoot '.tools/dotnet/dotnet.exe'
Assert-LabPath $dotnet | Out-Null
$project=Join-Path $labSigningRoot 'tools/Ses.DriverSigning/Ses.DriverSigning.csproj'
& $dotnet build $project -c Release --nologo -p:AnalysisLevel=latest-all
if($LASTEXITCODE -ne 0){throw 'Lab cryptographic tool build failed'}
$helper=Join-Path $labSigningRoot 'tools/Ses.DriverSigning/bin/Release/net10.0-windows/Ses.DriverSigning.dll'
Assert-LabPath $helper | Out-Null
$labTools=@('ses_driver_lab_tests.exe','ses_driver_capture_lab_tests.exe')
foreach($name in $labTools){
    $labTool=Join-Path $labSigningRoot ('build/bin/'+$name)
    Assert-LabPath $labTool | Out-Null
    if((Get-Item -LiteralPath $labTool).Length -gt 16MB){throw 'Lab test tool is oversized'}
}
$runRoot=Join-Path $labSigningRoot ('artifacts/driver-test-signing/'+[Guid]::NewGuid().ToString('N'))
Assert-LabPath $runRoot (Join-Path $labSigningRoot 'artifacts') -MayNotExist | Out-Null
New-Item -ItemType Directory -Path $runRoot | Out-Null
$packet=Join-Path $runRoot 'package'
New-Item -ItemType Directory -Path $packet | Out-Null
$private=New-LabPrivateDirectory (Join-Path $runRoot 'private')
$pfx=Join-Path $private 'lab-private.pfx'
try{
    foreach($name in $driverPayloadNames){Copy-Item -LiteralPath (Join-Path $inputPackage $name) -Destination (Join-Path $packet $name)}
    # Revalidate the copy immediately before signing; no stale or racing source copy.
    Copy-Item -LiteralPath (Join-Path $inputPackage 'development-manifest.json') -Destination $packet
    $source=Assert-TestSigningInput $packet
    $sourceManifestHash=(Get-FileHash -LiteralPath (Join-Path $packet 'development-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    Remove-Item -LiteralPath (Join-Path $packet 'development-manifest.json')
    & $dotnet $helper create $private
    if($LASTEXITCODE -ne 0){throw 'Ephemeral certificate creation failed'}
    Assert-LabPrivateAcl $pfx
    Copy-Item -LiteralPath (Join-Path $private 'lab-test.cer') -Destination (Join-Path $packet 'lab-test.cer')
    # Only the public certificate reaches SignTool. The helper imports the PFX
    # using EphemeralKeySet; no persistent key container or certificate store.
    foreach($name in @('SesMicrophone.sys','SesMicrophone.cat')){
        if($name -eq 'SesMicrophone.cat'){
            Remove-Item -LiteralPath (Join-Path $packet 'SesMicrophone.cat')
            & $tools.inf2cat.path "/driver:$packet" /os:10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64 /uselocaltime
            if($LASTEXITCODE -ne 0){throw 'Signed SYS catalog regeneration failed'}
        }
        & $tools.signtool.path sign /dg $private /fd SHA256 /f (Join-Path $private 'lab-test.cer') /d 'Veylo isolated lab TEST ONLY' (Join-Path $packet $name)
        if($LASTEXITCODE -ne 0){throw 'Signing digest creation failed'}
        $operation=if($name -eq 'SesMicrophone.sys'){'sign-sys-digest'}else{'sign-cat-digest'}
        & $dotnet $helper $operation $private
        if($LASTEXITCODE -ne 0){throw 'Ephemeral signing digest operation failed'}
        & $tools.signtool.path sign /di $private (Join-Path $packet $name)
        if($LASTEXITCODE -ne 0){throw 'Test signature ingestion failed'}
    }
}finally{
    # Remove only the exact transient names in this newly created private folder.
    foreach($name in @('lab-private.pfx','lab-test.cer','SesMicrophone.sys.dig','SesMicrophone.sys.dig.signed','SesMicrophone.sys.p7u','SesMicrophone.cat.dig','SesMicrophone.cat.dig.signed','SesMicrophone.cat.p7u')){
        $path=Join-Path $private $name
        if(Test-Path -LiteralPath $path){Assert-LabPath $path $private | Out-Null;Remove-Item -LiteralPath $path}
    }
}
if(@(Get-ChildItem -LiteralPath $private -Force).Count -ne 0){throw 'Private signing material was not removed'}
$verification=& $dotnet $helper verify $packet
if($LASTEXITCODE -ne 0){throw 'Cryptographic signature/catalog membership verification failed'}
$proof=$verification | ConvertFrom-Json
foreach($name in $labTools){Copy-Item -LiteralPath (Join-Path $labSigningRoot ('build/bin/'+$name)) -Destination (Join-Path $packet $name)}
foreach($name in @('DRIVER.md','DRIVER-LAB.md')){Copy-Item -LiteralPath (Join-Path $labSigningRoot ('docs/'+$name)) -Destination (Join-Path $packet $name)}
Copy-Item -LiteralPath (Join-Path $labSigningRoot 'LICENSE') -Destination (Join-Path $packet 'LICENSE')
@'
VEYLO: ISOLATED LAB TEST-SIGNED DRIVER ONLY

This package is signed with a self-signed 90-day test certificate. It is NOT
Microsoft production signed and is NOT ready for the daily-use computer.
The certificate is a PUBLIC .cer only. No private key or PFX is included.
No trusted certificate was installed on the development host. No test-signing,
Secure Boot, Memory Integrity, driver installation, or device policy was changed.

Cryptographic checks prove the SYS signature, CAT signature and INF/SYS catalog
membership against this explicit public certificate. They do not prove Windows
kernel policy acceptance, HVCI compatibility, live capture, timing or stability.
There is no timestamp; re-create this lab package after the test certificate expires.
Follow DRIVER-LAB.md only on a separately authorized, isolated Windows target.
The normal production installer intentionally rejects this certificate.
'@ | Set-Content -LiteralPath (Join-Path $packet 'README-TEST-SIGNED.txt') -Encoding utf8
$manifest=[ordered]@{
    schema=1;kind='Veylo isolated lab test signing';driverVersion=$source.driverVersion;appVersion=$source.appVersion;abi=$source.abi;protocol=$source.protocol
    signed=$true;testOnly=$true;dailyUseReady=$false;microsoftProductionSigned=$false
    certificateThumbprint=$proof.certificateThumbprint;certificateSha256=$proof.certificateSha256;certificateNotAfterUtc=$proof.certificateNotAfterUtc
    sourceManifestSha256=$sourceManifestHash;unsignedSourceFiles=$source.files;verification=$proof
    signingTools=[ordered]@{kit=$source.kit;kitSha256=$source.kitSha256;signtoolSha256=$tools.signtool.sha256;inf2catSha256=$tools.inf2cat.sha256}
    files=(Get-LabFileHashes $packet)
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $packet 'test-signing-manifest.json') -Encoding utf8
Assert-TestSignedLabManifest $packet | Out-Null
$archivePath=Join-Path $runRoot ('Veylo-driver-'+$source.driverVersion+'-TEST-SIGNED-isolated-lab.zip')
$stream=[IO.File]::Open($archivePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
try{
    foreach($name in ($labPublicNames+@('test-signing-manifest.json'))){
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $packet $name),$name,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}finally{$archive.Dispose();$stream.Dispose()}
Assert-LabArchive $archivePath $packet
((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($archivePath)) | Set-Content -LiteralPath ($archivePath+'.sha256') -Encoding ascii
Write-Output $archivePath
Write-Output 'PASS SYS/CAT cryptography, catalog membership, fixed ZIP inventory, private-key deletion. Isolated lab TEST-SIGNED only; Windows kernel acceptance and daily readiness are not validated.'
