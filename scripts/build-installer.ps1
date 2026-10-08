param([switch]$TestFixture)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
[xml]$project=Get-Content -LiteralPath (Join-Path $root 'app/Ses.Desktop/Ses.Desktop.csproj')
$version=[string]$project.Project.PropertyGroup.Version
if($version -notmatch '^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$'){throw 'Invalid installer version'}
$payload=Join-Path $root ('dist/Veylo-'+$version+'-win-x64')
foreach($required in @('Veylo.exe','ses_native.dll','Veylo.runtimeconfig.json','release-status.json')){
    if(!(Test-Path -LiteralPath (Join-Path $payload $required) -PathType Leaf)){throw ('Missing installer payload: '+$required)}
}
$status=Get-Content -LiteralPath (Join-Path $payload 'release-status.json') -Raw | ConvertFrom-Json
if($status.version -ne $version -or $status.driverBundled -or $status.defaultOutput -ne 'VB-CABLE'){throw 'Incompatible installer payload'}
foreach($file in Get-ChildItem -LiteralPath $payload -Recurse -File){
    if($file.Extension -in @('.sys','.cat','.pfx','.p12','.key','.wav') -or $file.Name -eq 'state.json' -or $file.Name -like 'unins*'){throw ('Unexpected installer payload: '+$file.Name)}
}
& (Join-Path $PSScriptRoot 'bootstrap-installer.ps1')
$output=if($TestFixture){Join-Path $root 'artifacts/installer/fixture'}else{Join-Path $root 'dist'}
New-Item -ItemType Directory -Force -Path $output | Out-Null
$arguments=@(('--define=AppVersion='+$version),('--define=PayloadDir='+$payload),('--define=OutputPath='+$output),'--quiet')
if($TestFixture){$arguments+='--define=TestFixture=1'}
& (Join-Path $root '.tools/innosetup-7.1.0/ISCC.exe') @arguments (Join-Path $root 'installer/Veylo.iss')
if($LASTEXITCODE -ne 0){throw 'Installer compilation failed'}
$fileName=if($TestFixture){'Veylo-'+$version+'-test-setup.exe'}else{'Veylo-'+$version+'-win-x64-Setup.exe'}
$setup=Join-Path $output $fileName
((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+$fileName) | Set-Content -LiteralPath ($setup+'.sha256') -Encoding ASCII
Write-Output $setup
