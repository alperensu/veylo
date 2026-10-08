param([switch]$Sanitize)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try{
    & "$PSScriptRoot/bootstrap.ps1"
    & "$PSScriptRoot/verify-dependencies.ps1"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'
    $env:PATH=(Join-Path $root '.tools/llvm-mingw-20260922-ucrt-x86_64/bin')+';'+$env:PATH
    $cmake=Join-Path $root '.tools/cmake-4.4.4-windows-x86_64/bin/cmake.exe'
    $build=if($Sanitize){'build/asan'}else{'build'}
    $flag=if($Sanitize){'ON'}else{'OFF'}
    & $cmake -S . -B $build -G 'MinGW Makefiles' '-DCMAKE_C_COMPILER=clang.exe' '-DCMAKE_CXX_COMPILER=clang++.exe' '-DCMAKE_BUILD_TYPE=Release' "-DSES_SANITIZE=$flag"
    if($LASTEXITCODE -ne 0){throw 'CMake configuration failed'}
    & $cmake --build $build --parallel ([Math]::Min(8,[Environment]::ProcessorCount))
    if($LASTEXITCODE -ne 0){throw 'Native build failed'}
    if(!$Sanitize){& '.tools/dotnet/dotnet.exe' build app/Ses.DriverSetup -c Release;if($LASTEXITCODE -ne 0){throw 'Driver helper build failed'};& '.tools/dotnet/dotnet.exe' build app/Ses.Desktop -c Release;if($LASTEXITCODE -ne 0){throw 'Desktop build failed'}}
}finally{Pop-Location}
