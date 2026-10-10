param([Parameter(Mandatory)][string]$VmDirectory,[switch]$ReplaceStaged)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'driver-vm-common.ps1')
$owned=Get-OwnedVm $VmDirectory -VerifyInputs
$vm=$owned.directory
if(Test-Path -LiteralPath (Join-Path $vm 'process.json')){
    $record=Read-VmJson $vm 'process.json'
    foreach($identity in @(@{id=$record.processId;time=$record.startTimeUtc},@{id=$record.supervisorProcessId;time=$record.supervisorStartTimeUtc})){
        if($identity.id){
            $live=Get-Process -Id $identity.id -ErrorAction SilentlyContinue
            if($live -and $live.StartTime.ToUniversalTime().ToString('O') -ceq $identity.time){throw 'Stop the owned VM before staging read-only acceptance media'}
        }
    }
}
# The qcow2 must also be unlocked, even if stale process metadata exists.
$diskLock=[IO.File]::Open($owned.state.disk,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
try{
    $destination=Assert-LabPath (Join-Path $owned.state.seed 'acceptance') $owned.state.seed -MayNotExist
    $replacing=Test-Path -LiteralPath $destination
    if($replacing -and !$ReplaceStaged){throw 'Acceptance media already staged; use explicit ReplaceStaged to preserve and replace the verified stopped-VM payload'}
    $inputs=@{ 'driver-vm-acceptance.ps1'=(Join-Path $PSScriptRoot 'driver-vm-acceptance.ps1'); 'ses_driver_capture_lab_tests.exe'=(Join-Path $labSigningRoot 'build/bin/ses_driver_capture_lab_tests.exe') }
    foreach($path in $inputs.Values){
        Assert-LabPath $path | Out-Null
        $info=Get-Item -LiteralPath $path
        if($info.PSIsContainer -or $info.Length -lt 1 -or $info.Length -gt 16MB){throw 'Invalid acceptance input'}
    }
    if($replacing){
        Assert-VmAcceptanceSeed $owned.state.seed $owned.state.id | Out-Null
        $archive=New-LabPrivateDirectory (Join-Path $labSigningRoot ('artifacts/driver-test-signing/acceptance-history-'+[Guid]::NewGuid().ToString('N')))
        foreach($name in @('driver-vm-acceptance.ps1','ses_driver_capture_lab_tests.exe','acceptance-manifest.json')){
            Copy-Item -LiteralPath (Join-Path $destination $name) -Destination (Join-Path $archive $name)
        }
    }else{New-LabPrivateDirectory $destination | Out-Null}
    $hashes=[ordered]@{}
    foreach($name in @('driver-vm-acceptance.ps1','ses_driver_capture_lab_tests.exe')){
        Copy-Item -LiteralPath $inputs[$name] -Destination (Join-Path $destination $name)
        $hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $destination $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    @{schema=1;testOnly=$true;vmId=$owned.state.id;files=$hashes} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'acceptance-manifest.json') -Encoding utf8
    Assert-VmAcceptanceSeed $owned.state.seed $owned.state.id | Out-Null
    Write-Output 'Passed: fixed hashed acceptance tools staged on owned read-only seed; no host driver or security changes'
    Write-Output $destination
}finally{$diskLock.Dispose()}
