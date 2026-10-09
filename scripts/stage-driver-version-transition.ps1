param([Parameter(Mandatory)][string]$VmDirectory,[Parameter(Mandatory)][string]$PreparedDirectory,[switch]$ReplaceStaged)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'driver-vm-common.ps1')
$owned=Get-OwnedVm $VmDirectory -VerifyInputs
$source=Assert-LabPath $PreparedDirectory (Join-Path $labSigningRoot 'artifacts/driver-test-signing')
$source=Assert-VmVersionTransitionPayload $source $owned.state.id
$runner=Join-Path $PSScriptRoot 'driver-vm-version-transition.ps1'
if((Get-FileHash -LiteralPath (Join-Path $source 'driver-vm-version-transition.ps1') -Algorithm SHA256).Hash -cne
   (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash){throw 'Prepared runner is not the current source'}
if(Test-Path -LiteralPath (Join-Path $owned.directory 'process.json')){
    $record=Read-VmJson $owned.directory 'process.json'
    foreach($identity in @(@{id=$record.processId;time=$record.startTimeUtc},@{id=$record.supervisorProcessId;time=$record.supervisorStartTimeUtc})){
        if($identity.id){$live=Get-Process -Id $identity.id -ErrorAction SilentlyContinue
            if($live -and $live.StartTime.ToUniversalTime().ToString('O') -ceq $identity.time){throw 'Stop the owned VM before staging version transition media'}}
    }
}
$diskLock=[IO.File]::Open($owned.state.disk,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
try{
    $destination=Assert-LabPath (Join-Path $owned.state.seed 'version-transition') $owned.state.seed -MayNotExist
    $replacing=Test-Path -LiteralPath $destination
    if($replacing -and !$ReplaceStaged){throw 'Preserve existing version transition media; explicit ReplaceStaged archives the verified old payload before replacement'}
    # Complete and validate the private copy outside the seed before its atomic move.
    $temporary=New-LabPrivateDirectory (Join-Path $labSigningRoot ('artifacts/driver-test-signing/version-transition-stage-'+[Guid]::NewGuid().ToString('N')))
    foreach($name in @('driver-vm-version-transition.ps1','version-transition-manifest.json')){
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $temporary $name)
    }
    foreach($version in @('old','current')){
        $subdirectory=New-LabPrivateDirectory (Join-Path $temporary $version)
        foreach($name in @('SesMicrophone.inf','SesMicrophone.sys','SesMicrophone.cat','lab-test.cer','ses_driver_capture_lab_tests.exe','test-signing-manifest.json')){
            Copy-Item -LiteralPath (Join-Path $source ($version+'/'+$name)) -Destination (Join-Path $subdirectory $name)
        }
    }
    Assert-VmVersionTransitionPayload $temporary $owned.state.id | Out-Null
    # Both fully resolved paths were checked within their explicit workspace roots.
    if([IO.Path]::GetPathRoot($temporary) -ine [IO.Path]::GetPathRoot($destination)){throw 'Atomic staging requires the same volume'}
    $archive=$null
    if($replacing){
        Assert-VmVersionTransitionPayload $destination $owned.state.id | Out-Null
        $history=New-LabPrivateDirectory (Join-Path $labSigningRoot ('artifacts/driver-test-signing/version-transition-history-'+[Guid]::NewGuid().ToString('N')))
        $archive=Assert-LabPath (Join-Path $history 'payload') $history -MayNotExist
        if([IO.Path]::GetPathRoot($archive) -ine [IO.Path]::GetPathRoot($destination)){throw 'Version archive requires the same volume'}
        [IO.Directory]::Move($destination,$archive)
    }
    try{[IO.Directory]::Move($temporary,$destination)}catch{
        # Never delete or overwrite a newly appeared destination. Restore the
        # original only when that fixed destination is still absent.
        if($archive -and !(Test-Path -LiteralPath $destination)){[IO.Directory]::Move($archive,$destination)}
        throw
    }
    Assert-VmVersionTransitionPayload $destination $owned.state.id | Out-Null
    Write-Output 'Passed: fixed historical/current version payload staged on stopped owned VM; no host driver or trust changes'
    Write-Output $destination
}finally{$diskLock.Dispose()}
