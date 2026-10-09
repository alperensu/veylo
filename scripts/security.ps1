$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try{
    & "$PSScriptRoot/bootstrap.ps1" -Security
    & "$PSScriptRoot/verify-dependencies.ps1"
    $reports=Join-Path $root 'artifacts/security';New-Item -ItemType Directory -Force -Path $reports | Out-Null
    & '.tools/gitleaks/gitleaks.exe' dir . --config .gitleaks.toml --redact --max-target-megabytes 1 --report-format json --report-path (Join-Path $reports 'secrets.json')
    if($LASTEXITCODE -ne 0){throw 'Secret scan failed'}
    & '.tools/dotnet/dotnet.exe' list app/Ses.Desktop package --vulnerable --include-transitive --format json | Set-Content (Join-Path $reports 'nuget.json')
    if($LASTEXITCODE -ne 0){throw 'NuGet vulnerability lookup failed'}
    $packages=Get-Content (Join-Path $reports 'nuget.json') -Raw | ConvertFrom-Json
    foreach($project in $packages.projects){foreach($framework in $project.frameworks){if($framework.topLevelPackages.Count -or $framework.transitivePackages.Count){throw 'Review vulnerable NuGet packages'}}}
    $lock=Get-Content dependencies.lock.json -Raw | ConvertFrom-Json
    $clang=Join-Path $root '.tools/llvm-mingw-20260922-ucrt-x86_64/bin/clang++.exe'
    $preprocessed=Join-Path $reports 'ses-preprocessed.cpp'
    & $clang -E -std=c++20 -DSES_BUILD -DWIN32_LEAN_AND_MEAN -DNOMINMAX -Inative/include -Inative/src -Ithird_party -Ithird_party/rnnoise/include native/src/ses.cpp -o $preprocessed
    if($LASTEXITCODE -ne 0){throw 'Native security preprocessing failed'}
    $excludedDecoder=!(Select-String -LiteralPath $preprocessed -Pattern 'ma_dr_wav__metadata_process_chunk|ma_dr_wav__read_bext_to_metadata_obj' -Quiet)
    $osv=@();foreach($component in @($lock.miniaudio,$lock.rnnoise)){
        $result=Invoke-RestMethod -Uri 'https://api.osv.dev/v1/query' -Method Post -ContentType 'application/json' -Body (@{commit=$component.commit}|ConvertTo-Json)
        $dispositions=@();foreach($finding in $result.vulns){
            if($component.url -eq 'https://github.com/mackron/miniaudio' -and $finding.id -eq 'CVE-2026-32837' -and $excludedDecoder){$dispositions+=@{id=$finding.id;status='not_affected';reason='MA_NO_DECODING removes vulnerable BEXT WAV parser. Checked preprocessed translation unit; no external audio file import.'}}
            else{$osv+=@{component=$component.url;commit=$component.commit;result=$result};$osv|ConvertTo-Json -Depth 32|Set-Content (Join-Path $reports 'native-osv.json');throw 'Review native vulnerability findings'}
        }
        $osv+=@{component=$component.url;commit=$component.commit;result=$result;dispositions=$dispositions}
    }
    $osv|ConvertTo-Json -Depth 32|Set-Content (Join-Path $reports 'native-osv.json')
    & $clang --analyze -std=c++20 -DSES_BUILD -DWIN32_LEAN_AND_MEAN -DNOMINMAX -Inative/include -Inative/src -Ithird_party -Ithird_party/rnnoise/include -Xanalyzer -analyzer-output=text native/src/ses.cpp 2>&1 | Tee-Object (Join-Path $reports 'clang.txt')
    if($LASTEXITCODE -ne 0){throw 'Clang analysis failed'}
    $findings=@(Select-String -LiteralPath (Join-Path $reports 'clang.txt') -Pattern 'warning:|error:')
    foreach($finding in $findings){
        # Exact upstream locations below are reviewed redundant initial assignments,
        # not ignored memory/security diagnostics. Any other finding fails the check.
        if($finding.Line -notmatch '^third_party[/\\]miniaudio.h:(23693:5|23856:9): warning: Value stored.*\[deadcode.DeadStores\]'){throw 'Review Clang static analysis finding'}
    }
    @{reviewedInformational=$findings.Count;reason='Two upstream dead initial stores overwritten before use; no memory or security diagnostic';decoderCve='CVE-2026-32837 not affected: vulnerable decoder compiled out'} | ConvertTo-Json | Set-Content (Join-Path $reports 'reviewed-findings.json')
    & '.tools/dotnet/dotnet.exe' build app/Ses.Desktop -c Release -p:RunAnalyzers=true -p:TreatWarningsAsErrors=true
    if($LASTEXITCODE -ne 0){throw 'Managed analyzers failed'}
    & '.tools/dotnet/dotnet.exe' build app/Ses.DriverSetup -c Release -p:RunAnalyzers=true -p:TreatWarningsAsErrors=true
    if($LASTEXITCODE -ne 0){throw 'Driver helper analyzers failed'}
    & '.tools/dotnet/dotnet.exe' list app/Ses.DriverSetup package --vulnerable --include-transitive --format json | Set-Content (Join-Path $reports 'driver-helper-nuget.json')
    if($LASTEXITCODE -ne 0){throw 'Driver helper dependency scan failed'}
    & '.tools/dotnet/dotnet.exe' build tools/Ses.DriverSigning -c Release -p:AnalysisLevel=latest-all -p:RunAnalyzers=true -p:TreatWarningsAsErrors=true
    if($LASTEXITCODE -ne 0){throw 'Lab signing helper analyzers failed'}
    & '.tools/dotnet/dotnet.exe' list tools/Ses.DriverSigning package --vulnerable --include-transitive --format json | Set-Content (Join-Path $reports 'lab-signing-nuget.json')
    if($LASTEXITCODE -ne 0){throw 'Lab signing helper dependency lookup failed'}
    $labPackages=Get-Content (Join-Path $reports 'lab-signing-nuget.json') -Raw | ConvertFrom-Json
    foreach($project in $labPackages.projects){foreach($framework in $project.frameworks){if($framework.topLevelPackages.Count -or $framework.transitivePackages.Count){throw 'Review vulnerable lab signing packages'}}}
    Write-Output 'Security checks passed (scope and limits: SECURITY.md)'
}finally{Pop-Location}
