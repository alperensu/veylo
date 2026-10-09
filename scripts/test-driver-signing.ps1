# Integrity/rejection checks only. Runs without WDK, certificate-store import,
# test signing, driver loading, VM provisioning or host security policy changes.
param([string]$SignedPackageDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'driver-signing.ps1')
$fixture=Join-Path $labSigningRoot ('artifacts/driver-test-signing/tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$inputFixture=Join-Path $fixture 'input'
$outputFixture=Join-Path $fixture 'package'
New-Item -ItemType Directory -Path $inputFixture | Out-Null
New-Item -ItemType Directory -Path $outputFixture | Out-Null
$checks=0
function Reject-Lab([string]$Name,[scriptblock]$Action){
    $rejected=$false
    try{& $Action | Out-Null}catch{$rejected=$true}
    if(!$rejected){throw ('Accepted unsafe lab data: '+$Name)}
    $script:checks++;Write-Output ('PASS '+$Name)
}
function Write-LabFixtureManifest {
    $contract=Get-DriverContract
    $manifest=[ordered]@{
        schema=1;kind='Veylo isolated lab test signing';driverVersion=$contract.driverVersion;appVersion=$contract.appVersion;abi=$contract.abi;protocol=$contract.protocol
        signed=$true;testOnly=$true;dailyUseReady=$false;microsoftProductionSigned=$false
        certificateThumbprint=('a'*40);certificateSha256=(Get-FileHash -LiteralPath (Join-Path $outputFixture 'lab-test.cer') -Algorithm SHA256).Hash.ToLowerInvariant()
        sourceManifestSha256=('b'*64);unsignedSourceFiles=(Get-DriverPayloadHashes $inputFixture);files=(Get-LabFileHashes $outputFixture)
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputFixture 'test-signing-manifest.json') -Encoding utf8
}
Copy-Item -LiteralPath (Join-Path $labSigningRoot 'driver/SesMicrophone.inf') -Destination $inputFixture
foreach($name in @('SesMicrophone.sys','SesMicrophone.cat','SYSVAD-LICENSE')){[IO.File]::WriteAllBytes((Join-Path $inputFixture $name),[byte[]](1,2,3,4))}
New-DevelopmentDriverManifest $inputFixture
Assert-TestSigningInput $inputFixture | Out-Null
$checks++;Write-Output 'PASS fixed unsigned source manifest accepted for integrity tests only'
foreach($name in @('lab-private.pfx','unknown.sys','outside.key')){
    $path=Join-Path $inputFixture $name
    [IO.File]::WriteAllBytes($path,[byte[]](1))
    Reject-Lab ('unsigned input rejects '+$name) {Assert-TestSigningInput $inputFixture}
    Remove-Item -LiteralPath $path
}
$inputManifest=Get-Content -LiteralPath (Join-Path $inputFixture 'development-manifest.json') -Raw | ConvertFrom-Json
$inputManifest.kitSha256='a'*64
$inputManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $inputFixture 'development-manifest.json') -Encoding utf8
Reject-Lab 'unbound EWDK provenance rejected' {Assert-TestSigningInput $inputFixture}
New-DevelopmentDriverManifest $inputFixture
Copy-Item -LiteralPath (Join-Path $inputFixture 'SesMicrophone.inf') -Destination $outputFixture
foreach($name in $labPublicNames){if($name -ne 'SesMicrophone.inf'){[IO.File]::WriteAllBytes((Join-Path $outputFixture $name),[byte[]](1,2,3,4))}}
Write-LabFixtureManifest
Assert-TestSignedLabManifest $outputFixture | Out-Null
$checks++;Write-Output 'PASS fixed lab inventory and source INF hash; dummy files do not claim cryptographic acceptance'
foreach($mutation in @(
    @{name='daily-use claim rejected';field='dailyUseReady';value=$true},
    @{name='Microsoft-production claim rejected';field='microsoftProductionSigned';value=$true},
    @{name='missing test-only boundary rejected';field='testOnly';value=$false},
    @{name='string boolean rejected';field='testOnly';value='true'},
    @{name='stale app version rejected';field='appVersion';value='0.0.0'},
    @{name='stale ABI rejected';field='abi';value=999},
    @{name='malformed certificate thumbprint rejected';field='certificateThumbprint';value='not-a-certificate'}
)){
    $manifest=Get-Content -LiteralPath (Join-Path $outputFixture 'test-signing-manifest.json') -Raw | ConvertFrom-Json
    $manifest.($mutation.field)=$mutation.value
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputFixture 'test-signing-manifest.json') -Encoding utf8
    Reject-Lab $mutation.name {Assert-TestSignedLabManifest $outputFixture}
    Write-LabFixtureManifest
}
$manifest=Get-Content -LiteralPath (Join-Path $outputFixture 'test-signing-manifest.json') -Raw | ConvertFrom-Json
$manifest.files | Add-Member -NotePropertyName '../outside.pfx' -NotePropertyValue ('a'*64)
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputFixture 'test-signing-manifest.json') -Encoding utf8
Reject-Lab 'manifest path traversal/private key entry rejected' {Assert-TestSignedLabManifest $outputFixture}
Write-LabFixtureManifest
foreach($name in @('SesMicrophone.sys','lab-test.cer','ses_driver_lab_tests.exe','ses_driver_capture_lab_tests.exe','DRIVER-LAB.md')){
    $path=Join-Path $outputFixture $name
    [IO.File]::WriteAllBytes($path,[byte[]](9,9))
    Reject-Lab ('tampered '+$name+' rejected') {Assert-TestSignedLabManifest $outputFixture}
    [IO.File]::WriteAllBytes($path,[byte[]](1,2,3,4))
}
$secret=Join-Path $outputFixture 'lab-private.pfx'
[IO.File]::WriteAllBytes($secret,[byte[]](1))
Reject-Lab 'private signing file in output rejected' {Assert-TestSignedLabManifest $outputFixture}
Remove-Item -LiteralPath $secret
$oversized=Join-Path $outputFixture 'SesMicrophone.sys'
$file=[IO.File]::OpenWrite($oversized);try{$file.SetLength(16MB+1)}finally{$file.Dispose()}
Reject-Lab 'oversized output rejected' {Assert-TestSignedLabManifest $outputFixture}
[IO.File]::WriteAllBytes($oversized,[byte[]](1,2,3,4))
Reject-Lab 'outside-root path rejected' {Assert-LabPath ([IO.Path]::GetTempPath())}
Reject-Lab 'NTFS alternate data stream rejected' {Assert-LabPath ($oversized+':stream') -MayNotExist}
$reparse=Join-Path $fixture 'junction'
New-Item -ItemType Junction -Path $reparse -Target $outputFixture | Out-Null
Reject-Lab 'reparse directory rejected' {Assert-LabInventory $reparse $labPublicNames}
Reject-Lab 'reparse ancestor rejected' {Assert-LabPath (Join-Path $reparse 'SesMicrophone.sys')}
# Removing only our junction (without recursion) leaves the target intact.
[IO.Directory]::Delete($reparse)
$zip=Join-Path $fixture 'fixture.zip'
foreach($mode in @('valid','traversal','duplicate','secret','tamper')){
    $stream=[IO.File]::Open($zip,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    try{
        foreach($name in ($labPublicNames+@('test-signing-manifest.json'))){
            $entryName=if($mode -eq 'traversal' -and $name -eq 'LICENSE'){'../LICENSE'}else{$name}
            if($mode -eq 'tamper' -and $name -eq 'LICENSE'){
                $entry=$archive.CreateEntry($entryName);$content=$entry.Open();try{$content.WriteByte(9)}finally{$content.Dispose()}
            }else{[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $outputFixture $name),$entryName,[IO.Compression.CompressionLevel]::Optimal) | Out-Null}
        }
        if($mode -in @('duplicate','secret')){$entryName=if($mode -eq 'secret'){'lab-private.pfx'}else{'LICENSE'};[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $outputFixture 'LICENSE'),$entryName,[IO.Compression.CompressionLevel]::Optimal) | Out-Null}
    }finally{$archive.Dispose();$stream.Dispose()}
    if($mode -eq 'valid'){Assert-LabArchive $zip $outputFixture;$checks++;Write-Output 'PASS fixed lab ZIP inventory and hashes'}else{Reject-Lab ('ZIP '+$mode+' rejected without extraction') {Assert-LabArchive $zip $outputFixture}}
}
if($SignedPackageDirectory){
    # These checks copy public files only. They never sign or use a private key.
    $signed=Assert-LabPath $SignedPackageDirectory
    Assert-TestSignedLabManifest $signed | Out-Null
    $dotnet=Assert-LabPath (Join-Path $labSigningRoot '.tools/dotnet/dotnet.exe')
    $helper=Assert-LabPath (Join-Path $labSigningRoot 'tools/Ses.DriverSigning/bin/Release/net10.0-windows/Ses.DriverSigning.dll')
    & $dotnet $helper verify $signed | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Actual signed package cryptography failed'}
    $checks++;Write-Output 'PASS actual SYS/CAT signatures and catalog content digests'
    $cryptoFixture=Join-Path $fixture 'crypto'
    New-Item -ItemType Directory -Path $cryptoFixture | Out-Null
    foreach($name in @('SesMicrophone.sys','SesMicrophone.cat','SesMicrophone.inf','lab-test.cer')){Copy-Item -LiteralPath (Join-Path $signed $name) -Destination (Join-Path $cryptoFixture $name)}
    foreach($name in @('SesMicrophone.sys','SesMicrophone.cat','SesMicrophone.inf','lab-test.cer')){
        $path=Join-Path $cryptoFixture $name
        $bytes=[IO.File]::ReadAllBytes($path)
        $byte=if($name -eq 'SesMicrophone.sys'){4096}else{$bytes.Length-1}
        $bytes[$byte]=$bytes[$byte] -bxor 1
        [IO.File]::WriteAllBytes($path,$bytes)
        Reject-Lab ('actual cryptographic tampering in '+$name+' rejected') {
            & $dotnet $helper verify $cryptoFixture 2>&1 | Out-Null
            if($LASTEXITCODE -ne 0){throw 'Expected cryptographic rejection'}
        }
        Copy-Item -LiteralPath (Join-Path $signed $name) -Destination $path -Force
    }
}
Write-Output "$checks lab signing integrity checks passed; no signing, driver, certificate-store or OS-policy operations run"
