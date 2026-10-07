param([switch]$Security)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$toolRoot = Join-Path $root '.tools'
New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
$packages = @(
    @{ Name='dotnet'; File='dotnet.zip'; Url='https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.401/dotnet-sdk-10.0.401-win-x64.zip'; Hash='24b670ad3d923bfcf47df6c3b034152398b42f6dbc388e10d783aee1cfb5e5817d399fc0ae2a12cfa822a55e61d34830ccb15c50ef6efee437ab874bb7c79430'; Algorithm='SHA512'; Marker='dotnet/dotnet.exe'; Destination='dotnet' },
    @{ Name='LLVM'; File='llvm.zip'; Url='https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/llvm-mingw-20260922-ucrt-x86_64.zip'; Hash='e3ad77d117a4bea19a7a3b333341824d79a5a371004a10e25b8504e7b3047666'; Algorithm='SHA256'; Marker='llvm-mingw-20260922-ucrt-x86_64/bin/clang.exe'; Destination='' },
    @{ Name='CMake'; File='cmake.zip'; Url='https://github.com/Kitware/CMake/releases/download/v4.4.4/cmake-4.4.4-windows-x86_64.zip'; Hash='bace36e94b31c68ab6fa295f26dfa11219e0701cf7c94b0284a7d1cb13dac536'; Algorithm='SHA256'; Marker='cmake-4.4.4-windows-x86_64/bin/cmake.exe'; Destination='' }
)
if ($Security) { $packages += @{ Name='Gitleaks'; File='gitleaks.zip'; Url='https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip'; Hash='d29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e'; Algorithm='SHA256'; Marker='gitleaks/gitleaks.exe'; Destination='gitleaks' } }
foreach ($package in $packages) {
    if (Test-Path -LiteralPath (Join-Path $toolRoot $package.Marker)) { Write-Output ($package.Name + ' already available'); continue }
    $archive = Join-Path $toolRoot $package.File
    Write-Output ('Downloading ' + $package.Name)
    if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm $package.Algorithm).Hash.ToLowerInvariant() -ne $package.Hash) {
        & curl.exe --fail --location --silent --show-error --retry 3 --output $archive $package.Url
        if ($LASTEXITCODE -ne 0) { throw ('Download failed: ' + $package.Name) }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm $package.Algorithm).Hash.ToLowerInvariant() -ne $package.Hash) { throw ('Checksum mismatch: ' + $package.Name) }
    $destination = if ($package.Destination) { Join-Path $toolRoot $package.Destination } else { $toolRoot }
    Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
    Write-Output ($package.Name + ' verified and extracted')
}
