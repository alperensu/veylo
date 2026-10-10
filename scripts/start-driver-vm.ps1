param([Parameter(Mandatory)][string]$VmDirectory,[switch]$BootInstalled,[switch]$EvaluationActivationNetwork)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'VM control requires PowerShell 7'}
. (Join-Path $PSScriptRoot 'driver-vm-common.ps1')
$owned=Get-OwnedVm $VmDirectory -VerifyInputs;$vm=$owned.directory
if(Test-Path -LiteralPath (Join-Path $vm 'process.json')){
    $prior=Read-VmJson $vm 'process.json'
    foreach($identity in @(@{id=$prior.processId;time=$prior.startTimeUtc},@{id=$prior.supervisorProcessId;time=$prior.supervisorStartTimeUtc})){
        if($identity.id){$existing=Get-Process -Id $identity.id -ErrorAction SilentlyContinue
            if($existing -and $existing.StartTime.ToUniversalTime().ToString('O') -ceq $identity.time){throw 'This VM is already running'}}
    }
    if(!$BootInstalled -and !$owned.state.installed){throw 'Initial ISO boot is allowed once; use -BootInstalled to resume the owned disk'}
}
$session=[Guid]::NewGuid().ToString('N');$shell=(Get-Process -Id $PID).Path
$script=Join-Path $PSScriptRoot 'run-driver-vm.ps1'
$arguments=@('-NoProfile','-NonInteractive','-File',('"'+$script+'"'),'-VmDirectory',('"'+$vm+'"'),'-SessionId',$session)
if($BootInstalled){$arguments+='-BootInstalled'}
if($EvaluationActivationNetwork){$arguments+='-EvaluationActivationNetwork'}
$supervisor=Start-Process -FilePath $shell -ArgumentList $arguments -PassThru -WindowStyle Hidden
$clock=[Diagnostics.Stopwatch]::StartNew()
while($clock.Elapsed.TotalSeconds -lt 20){
    if($supervisor.HasExited){throw 'VM supervisor exited before startup confirmation; inspect bounded stderr log'}
    if(Test-Path -LiteralPath (Join-Path $vm 'process.json')){
        $record=Read-VmJson $vm 'process.json'
        if($record.sessionId -ceq $session){
            if($record.phase -cne 'running'){throw 'VM supervisor startup failed; inspect bounded stderr log'}
            $qemu=Get-Process -Id $record.processId -ErrorAction SilentlyContinue
            if(!$qemu -or $qemu.HasExited -or $qemu.StartTime.ToUniversalTime().ToString('O') -cne $record.startTimeUtc){throw 'QEMU exited after startup handshake'}
            Write-Output ('Isolated VM running with private QMP stdio: '+$vm)
            Write-Output ('QEMU PID: '+$record.processId+'; supervisor PID: '+$supervisor.Id);return
        }
    }
    Start-Sleep -Milliseconds 100
}
if(!$supervisor.HasExited){$supervisor.Kill($true);$supervisor.WaitForExit(3000) | Out-Null}
throw 'VM supervisor startup confirmation deadline exceeded'
