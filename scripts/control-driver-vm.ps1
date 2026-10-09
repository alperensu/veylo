param([Parameter(Mandatory)][string]$VmDirectory,[Parameter(Mandatory)][ValidateSet('query-status','screendump','send-key','quit')][string]$Command,[string[]]$Keys=@())
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'VM control requires PowerShell 7'}
. (Join-Path $PSScriptRoot 'driver-vm-common.ps1')
$owned=Get-OwnedVm $VmDirectory;$vm=$owned.directory;$state=$owned.state
$process=Read-VmJson $vm 'process.json'
if($process.schema -ne 2 -or $process.phase -cne 'running' -or $process.qmp -cne 'private-stdio' -or $process.vmId -cne $state.id -or $process.sessionId -cnotmatch '^[0-9a-f]{32}$'){throw 'No matching private VM supervisor is running'}
$supervisor=Get-Process -Id $process.supervisorProcessId -ErrorAction SilentlyContinue
$qemu=Get-Process -Id $process.processId -ErrorAction SilentlyContinue
if(!$supervisor -or !$qemu -or $supervisor.StartTime.ToUniversalTime().ToString('O') -cne $process.supervisorStartTimeUtc -or $qemu.StartTime.ToUniversalTime().ToString('O') -cne $process.startTimeUtc -or $qemu.Path -ine (Join-Path $labSigningRoot '.tools/driver-lab/qemu/qemu-system-x86_64.exe')){throw 'VM process identity mismatch'}
$request=@{schema=1;vmId=$state.id;sessionId=$process.sessionId;requestId=[Guid]::NewGuid().ToString('N');command=$Command;keys=@($Keys);createdUtc=[DateTimeOffset]::UtcNow.ToString('O')}
Get-VmCommand ([pscustomobject]$request) $state.id $process.sessionId (Join-Path $vm 'screen.ppm') | Out-Null
$lockPath=Assert-LabPath (Join-Path $vm 'control.lock') $vm -MayNotExist
if(Test-Path -LiteralPath $lockPath){Assert-VmPrivateAcl $lockPath $vm | Out-Null}
$lockStream=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    Assert-VmPrivateAcl $lockPath $vm | Out-Null;Write-VmJson $vm 'command.json' $request
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt 12){
        if(Test-Path -LiteralPath (Join-Path $vm 'response.json')){
            $response=Read-VmJson $vm 'response.json'
            if($response.schema -eq 1 -and $response.sessionId -ceq $request.sessionId -and $response.requestId -ceq $request.requestId){
                if($response.ok -isnot [bool] -or !$response.ok){throw 'VM control command failed or was rejected'}
                $response.result | ConvertTo-Json -Compress;return
            }
        }
        Start-Sleep -Milliseconds 50
    }
    throw 'VM control response deadline exceeded'
}finally{$lockStream.Dispose()}
