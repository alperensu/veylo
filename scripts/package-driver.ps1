# Produces only an explicitly labelled lab kit. Never installs or test-signs it.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'driver-package.ps1')
$packet=Join-Path $root 'build/driver/package'
$manifest=Assert-DevelopmentDriverPackage $packet
$labTest=Join-Path $root 'build/bin/ses_driver_lab_tests.exe'
if(!(Test-Path -LiteralPath $labTest -PathType Leaf)){throw 'Build the native lab test tool first: ./scripts/build.ps1'}
$version=$manifest.driverVersion
$archivePath=Join-Path $root ('dist/Veylo-driver-'+$version+'-isolated-lab.zip')
New-Item -ItemType Directory -Force (Split-Path $archivePath) | Out-Null
$stream=[IO.File]::Open($archivePath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
try {
    $entries=[ordered]@{}
    foreach($name in $driverPayloadNames){$entries[$name]=Join-Path $packet $name}
    $entries['development-manifest.json']=Join-Path $packet 'development-manifest.json'
    $entries['ses_driver_lab_tests.exe']=$labTest
    $entries['DRIVER.md']=Join-Path $root 'docs/DRIVER.md'
    $entries['DRIVER-LAB.md']=Join-Path $root 'docs/DRIVER-LAB.md'
    $entries['LICENSE']=Join-Path $root 'LICENSE'
    foreach($entry in $entries.GetEnumerator()){
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$entry.Value,$entry.Key,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}finally{$archive.Dispose();$stream.Dispose()}
((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($archivePath)) | Set-Content -LiteralPath ($archivePath+'.sha256') -Encoding ascii
Write-Output $archivePath
Write-Output 'Unsigned lab kit only. No driver installed; no host security settings changed.'
