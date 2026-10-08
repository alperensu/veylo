param([switch]$SkipBuild,[string]$NativeBinary)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try{
    if(!$SkipBuild){& "$PSScriptRoot/build.ps1";& "$PSScriptRoot/test.ps1"}
    [xml]$desktopProject=Get-Content -LiteralPath 'app/Ses.Desktop/Ses.Desktop.csproj'
    $packageName='Veylo-'+$desktopProject.Project.PropertyGroup.Version+'-win-x64'
    $output=Join-Path $root ('dist/'+$packageName)
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $nativeArgs=@();if($NativeBinary){$nativeArgs=@('-p:NativeBinary='+[IO.Path]::GetFullPath($NativeBinary))}
    & '.tools/dotnet/dotnet.exe' publish app/Ses.Desktop -c Release -r win-x64 --self-contained true -p:RuntimeFrameworkVersion=10.0.11 -p:DebugType=None -p:DebugSymbols=false @nativeArgs -o $output
    if($LASTEXITCODE -ne 0){throw 'Publish failed'}
    & '.tools/dotnet/dotnet.exe' publish app/Ses.DriverSetup -c Release -r win-x64 --self-contained true -p:RuntimeFrameworkVersion=10.0.11 -p:DebugType=None -p:DebugSymbols=false -o $output
    if($LASTEXITCODE -ne 0){throw 'Driver helper publish failed'}
    foreach($file in @('LICENSE','THIRD_PARTY_NOTICES.md','README.md','CONTRIBUTING.md','SECURITY.md','dependencies.lock.json')){Copy-Item -LiteralPath (Join-Path $root $file) -Destination $output -Force}
    Copy-Item -LiteralPath (Join-Path $root 'docs') -Destination $output -Recurse -Force
    $licenses=Join-Path $output 'licenses';New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    Copy-Item third_party/MINIAUDIO-LICENSE (Join-Path $licenses 'MINIAUDIO-LICENSE') -Force
    Copy-Item third_party/rnnoise/COPYING (Join-Path $licenses 'RNNOISE-COPYING') -Force
    Copy-Item third_party/rnnoise/AUTHORS (Join-Path $licenses 'RNNOISE-AUTHORS') -Force
    Copy-Item -LiteralPath 'driver/upstream/sysvad/LICENSE' -Destination (Join-Path $licenses 'SYSVAD-LICENSE') -Force
    Copy-Item -LiteralPath 'driver/upstream.lock.json' -Destination $output -Force
    $assets=Get-Content app/Ses.Desktop/obj/project.assets.json -Raw | ConvertFrom-Json
    $cache=@($assets.packageFolders.PSObject.Properties)[0].Name
    if(!$cache){throw 'Cannot locate runtime package licenses'}
    Copy-Item -LiteralPath (Join-Path $cache 'microsoft.netcore.app.runtime.win-x64/10.0.11/LICENSE.TXT') -Destination (Join-Path $output 'LICENSE.txt') -Force
    Copy-Item -LiteralPath (Join-Path $cache 'microsoft.netcore.app.runtime.win-x64/10.0.11/THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $output 'ThirdPartyNotices.txt') -Force
    Copy-Item -LiteralPath (Join-Path $cache 'microsoft.windowsdesktop.app.runtime.win-x64/10.0.11/LICENSE') -Destination (Join-Path $licenses 'WPF-WINFORMS-LICENSE') -Force
    @{version=[string]$desktopProject.Project.PropertyGroup.Version;abi=5;driverProtocol=1;driverBundled=$false;defaultOutput="VB-CABLE";vbCableBundled=$false;dailyUseReady=$false;pending=@('Microsoft production signing','Isolated Windows 10/11 kernel validation','Receiving-application compatibility','Full-route performance measurements')} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $output 'release-status.json') -Encoding utf8
    $zip=Join-Path $root ('dist/'+$packageName+'.zip')
    Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip -Force -CompressionLevel Optimal
    ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+$packageName+'.zip') | Set-Content -LiteralPath ($zip+'.sha256') -Encoding ASCII
    Write-Output $zip
    if(Test-Path -LiteralPath 'build/driver/package/development-manifest.json'){
        $driverZip=Join-Path $root 'dist/Veylo-driver-0.5.0-development.zip'
        Copy-Item -LiteralPath 'docs/DRIVER.md' -Destination 'build/driver/package/DRIVER.md' -Force
        Compress-Archive -Path 'build/driver/package/*' -DestinationPath $driverZip -Force
        ((Get-FileHash -LiteralPath $driverZip -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($driverZip)) | Set-Content ($driverZip+'.sha256') -Encoding ASCII
        Write-Output $driverZip
    }
    $sourceZip=Join-Path $root ('dist/Veylo-'+$desktopProject.Project.PropertyGroup.Version+'-source.zip')
    $sourceFiles=@(& git ls-files --cached --others --exclude-standard)
    if($LASTEXITCODE -ne 0){throw 'Source inventory failed'}
    $sourceStream=[IO.File]::Open($sourceZip,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $archive=[IO.Compression.ZipArchive]::new($sourceStream,[IO.Compression.ZipArchiveMode]::Create)
    try{
        foreach($relative in ($sourceFiles | Sort-Object -Unique)){
            $absolute=[IO.Path]::GetFullPath((Join-Path $root $relative))
            if(!$absolute.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Source path escapes workspace'}
            if(Test-Path -LiteralPath $absolute -PathType Leaf){[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$absolute,$relative.Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal) | Out-Null}
        }
    }finally{$archive.Dispose();$sourceStream.Dispose()}
    ((Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($sourceZip)) | Set-Content -LiteralPath ($sourceZip+'.sha256') -Encoding ASCII
    Write-Output $sourceZip
}finally{Pop-Location}
