param([switch]$Live,[switch]$Sanitize)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try{
    $env:PATH=(Join-Path $root '.tools/llvm-mingw-20260922-ucrt-x86_64/bin')+';'+$env:PATH
    $build=if($Sanitize){'build/asan'}else{'build'}
    & '.tools/cmake-4.4.4-windows-x86_64/bin/ctest.exe' --test-dir $build --output-on-failure
    if($LASTEXITCODE -ne 0){throw 'Native tests failed'}
    if($Sanitize){return}
    $env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'
    & '.tools/dotnet/dotnet.exe' run --project tests/Ses.Core.Tests -c Release -- (Join-Path $root 'build/bin')
    if($LASTEXITCODE -ne 0){throw 'Managed tests failed'}
    $app=Join-Path $root 'app/Ses.Desktop/bin/Release/net10.0-windows/SES.exe'
    $output=Join-Path $root 'artifacts/ui'
    $process=Start-Process -FilePath $app -ArgumentList @('--smoke','--out',('"'+$output+'"')) -PassThru -Wait -WindowStyle Hidden
    if($process.ExitCode -ne 0){throw 'UI smoke failed'}
    if($Live){$process=Start-Process -FilePath $app -ArgumentList @('--validate-live','--out',('"'+$output+'"')) -PassThru -Wait -WindowStyle Hidden;if($process.ExitCode -ne 0){throw 'Live microphone test failed'}}
}finally{Pop-Location}
