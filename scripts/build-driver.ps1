param([string]$EwdkRoot,[switch]$DownloadKit)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $lock=Get-Content driver/ewdk.lock.json -Raw | ConvertFrom-Json
    if(!$EwdkRoot){
        $iso=Join-Path $root '.tools/ewdk/EWDK_26100.iso'
        if(!(Test-Path -LiteralPath $iso)){
            if(!$DownloadKit){throw 'Pinned EWDK is missing. Use -DownloadKit or -EwdkRoot for an already mounted kit.'}
            New-Item -ItemType Directory -Force (Split-Path $iso) | Out-Null
            if((Get-Volume -DriveLetter C).SizeRemaining -lt ($lock.bytes+5GB)){throw 'EWDK requires 20GB plus build space; insufficient free disk space.'}
            Invoke-WebRequest -Uri $lock.url -OutFile $iso
        }
        if((Get-Item -LiteralPath $iso).Length -ne $lock.bytes -or (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash -ne $lock.sha256){throw 'EWDK checksum mismatch'}
        $image=Get-DiskImage -ImagePath $iso
        if(!$image.Attached){$image=Mount-DiskImage -ImagePath $iso -Access ReadOnly -PassThru}
        $letter=($image | Get-Volume).DriveLetter
        if(!$letter){Start-Sleep -Seconds 2;$letter=($image | Get-Volume).DriveLetter}
        if(!$letter){throw 'Cannot access mounted EWDK'}
        $EwdkRoot=$letter+':\'
    }
    $EwdkRoot=[IO.Path]::GetFullPath($EwdkRoot)
    $environment=Join-Path $EwdkRoot 'BuildEnv/SetupBuildEnv.cmd'
    if(!(Test-Path -LiteralPath $environment) -or (Get-Content -LiteralPath $environment -Raw) -notmatch 'ge_release_svc_prod1.26100.6584'){throw 'Use the pinned EWDK 26100.6584'}
    python scripts/prepare-driver.py
    if($LASTEXITCODE -ne 0){throw 'SYSVAD verification/adaptation failed'}
    $batch=Join-Path $root 'build/driver/build.cmd'
    @('@echo off',('call "'+$environment+'" amd64'),'if errorlevel 1 exit /b 1',('msbuild "'+$root+'\driver\SesMicrophone.vcxproj" /p:Configuration=Release /p:Platform=x64 /m:4 /v:minimal /nologo'),'exit /b %errorlevel%') | Set-Content -LiteralPath $batch -Encoding ASCII
    & cmd.exe /d /c $batch 2>&1 | Tee-Object 'build/driver/build.log'
    if($LASTEXITCODE -ne 0){throw 'Kernel build failed'}
    $findings=Select-String -LiteralPath 'build/driver/build.log' -Pattern 'warning C|error C'
    if($findings){throw 'Review WDK analysis/compiler findings before packaging'}
    $packet=Join-Path $root 'build/driver/package';New-Item -ItemType Directory -Force $packet | Out-Null
    Copy-Item -LiteralPath 'driver/SesMicrophone.inf' -Destination $packet -Force
    Copy-Item -LiteralPath 'build/driver/bin/SesMicrophone.sys' -Destination $packet -Force
    $kit=Join-Path $EwdkRoot 'Program Files/Windows Kits/10'
    & (Join-Path $kit 'Tools/10.0.26100.0/x64/infverif.exe') /w (Join-Path $packet 'SesMicrophone.inf') 2>&1 | Tee-Object 'build/driver/infverif.log'
    if($LASTEXITCODE -ne 0){throw 'INF validation failed'}
    & (Join-Path $kit 'bin/10.0.26100.0/x86/Inf2Cat.exe') "/driver:$packet" /os:10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64 /uselocaltime 2>&1 | Tee-Object 'build/driver/inf2cat.log'
    if($LASTEXITCODE -ne 0){throw 'Catalog generation failed'}
    Copy-Item -LiteralPath 'driver/upstream/sysvad/LICENSE' -Destination (Join-Path $packet 'SYSVAD-LICENSE') -Force
    $hashes=@{};Get-ChildItem -LiteralPath $packet -File | ForEach-Object {$hashes[$_.Name]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    @{schema=1;version='0.5.0-dev';signed=$false;dailyUseReady=$false;abi=4;protocol=1;kit=$lock.kit;sysvadCommit=(Get-Content driver/upstream.lock.json -Raw | ConvertFrom-Json).commit;files=$hashes} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $packet 'development-manifest.json')
    Write-Output 'Development driver built and analyzed. Not signed, not installed, not validated in a Windows lab.'
} finally {Pop-Location}
