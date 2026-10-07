param([switch]$SkipBuild)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try{
    if(!$SkipBuild){& "$PSScriptRoot/build.ps1";& "$PSScriptRoot/test.ps1"}
    $output=Join-Path $root 'dist/SES-0.1.0-win-x64'
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    & '.tools/dotnet/dotnet.exe' publish app/Ses.Desktop -c Release -r win-x64 --self-contained true -p:RuntimeFrameworkVersion=10.0.11 -p:DebugType=None -p:DebugSymbols=false -o $output
    if($LASTEXITCODE -ne 0){throw 'Publish failed'}
    foreach($file in @('LICENSE','THIRD_PARTY_NOTICES.md','README.md','dependencies.lock.json')){Copy-Item -LiteralPath (Join-Path $root $file) -Destination $output -Force}
    Copy-Item -LiteralPath (Join-Path $root 'docs') -Destination $output -Recurse -Force
    $licenses=Join-Path $output 'licenses';New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    Copy-Item third_party/MINIAUDIO-LICENSE (Join-Path $licenses 'MINIAUDIO-LICENSE') -Force
    Copy-Item third_party/rnnoise/COPYING (Join-Path $licenses 'RNNOISE-COPYING') -Force
    Copy-Item third_party/rnnoise/AUTHORS (Join-Path $licenses 'RNNOISE-AUTHORS') -Force
    $assets=Get-Content app/Ses.Desktop/obj/project.assets.json -Raw | ConvertFrom-Json
    $cache=@($assets.packageFolders.PSObject.Properties)[0].Name
    if(!$cache){throw 'Cannot locate runtime package licenses'}
    Copy-Item -LiteralPath (Join-Path $cache 'microsoft.netcore.app.runtime.win-x64/10.0.11/LICENSE.TXT') -Destination (Join-Path $output 'LICENSE.txt') -Force
    Copy-Item -LiteralPath (Join-Path $cache 'microsoft.netcore.app.runtime.win-x64/10.0.11/THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $output 'ThirdPartyNotices.txt') -Force
    Copy-Item -LiteralPath (Join-Path $cache 'microsoft.windowsdesktop.app.runtime.win-x64/10.0.11/LICENSE') -Destination (Join-Path $licenses 'WPF-WINFORMS-LICENSE') -Force
    $zip=Join-Path $root 'dist/SES-0.1.0-win-x64.zip'
    Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip -Force -CompressionLevel Optimal
    ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()+'  SES-0.1.0-win-x64.zip') | Set-Content -LiteralPath ($zip+'.sha256') -Encoding ASCII
    Write-Output $zip
}finally{Pop-Location}
