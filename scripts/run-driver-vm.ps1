param([Parameter(Mandatory)][string]$VmDirectory,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$SessionId,[switch]$BootInstalled)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'VM control requires PowerShell 7'}
. (Join-Path $PSScriptRoot 'driver-vm-common.ps1')
$owned=Get-OwnedVm $VmDirectory -VerifyInputs;$vm=$owned.directory;$state=$owned.state
$base=Join-Path $labSigningRoot '.tools/driver-lab';$transport=$null;$lockStream=$null;$record=$null
try{
    $lockPath=Assert-LabPath (Join-Path $vm 'supervisor.lock') $vm -MayNotExist
    if(Test-Path -LiteralPath $lockPath){Assert-VmPrivateAcl $lockPath $vm | Out-Null}
    $lockStream=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    Assert-VmPrivateAcl $lockPath $vm | Out-Null
    $diskBoot=$BootInstalled -or $state.installed
    foreach($name in @('serial.log','qemu-stderr.log','screen.ppm')){
        $path=Assert-LabPath (Join-Path $vm $name) $vm -MayNotExist
        if(Test-Path -LiteralPath $path){Assert-VmPrivateAcl $path $vm | Out-Null}
    }
    $arguments=Get-VmArguments $vm $state -BootInstalled:$BootInstalled
    Initialize-VmQmpTransport
    $transport=[VeyloLab.QmpProcess]::new((Join-Path $base 'qemu/qemu-system-x86_64.exe'),[string[]]$arguments,(Join-Path $vm 'qemu-stderr.log'))
    Connect-VmQmp $transport | Out-Null
    if($transport.HasExited){throw 'QEMU exited before readiness publication'}
    $self=Get-Process -Id $PID
    $record=@{schema=2;processId=$transport.Id;startTimeUtc=$transport.StartTimeUtc;supervisorProcessId=$PID;supervisorStartTimeUtc=$self.StartTime.ToUniversalTime().ToString('O');vmId=$state.id;sessionId=$SessionId;phase='running';qmp='private-stdio';bootMode=$(if($diskBoot){'installed-disk'}else{'initial-iso'})}
    Write-VmJson $vm 'process.json' $record
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while(!$transport.HasExited){
        if($transport.Fault){throw 'QMP transport failed'}
        $line=$null
        while($transport.TryRead([ref]$line)){
            $event=$line | ConvertFrom-Json
            if($event.PSObject.Properties.Name -notcontains 'event'){throw 'Unexpected idle QMP message'}
        }
        if(Test-Path -LiteralPath (Join-Path $vm 'command.json')){
            $request=Read-VmJson $vm 'command.json'
            if($request.sessionId -ceq $SessionId -and $request.requestId -cmatch '^[0-9a-f]{32}$' -and !$seen.Contains($request.requestId)){
                if($seen.Count -ge 4096){throw 'VM control session operation limit reached'}
                $seen.Add($request.requestId) | Out-Null
                $response=@{schema=1;sessionId=$SessionId;requestId=$request.requestId;ok=$false;result=@{};error='Control operation rejected'}
                try{
                    $screen=Assert-LabPath (Join-Path $vm 'screen.ppm') $vm -MayNotExist
                    if(Test-Path -LiteralPath $screen){Assert-VmPrivateAcl $screen $vm | Out-Null}
                    $command=Get-VmCommand $request $state.id $SessionId $screen
                    $result=Invoke-VmQmp $transport $command
                    $response.ok=$true;$response.error=$null
                    if($command.execute -ceq 'query-status'){$response.result=@{running=[bool]$result.running;status=[string]$result.status}}
                    elseif($command.execute -ceq 'screendump'){Assert-VmPrivateAcl $screen $vm | Out-Null;$response.result=@{screenWritten=$true}}
                    elseif($command.execute -ceq 'quit'){$response.result=@{quitRequested=$true}}
                    else{$response.result=@{keysSent=$true}}
                }catch{$response.ok=$false;$response.error='Allowlisted QMP operation failed or was rejected'}
                Write-VmJson $vm 'response.json' $response
                if($request.command -ceq 'quit' -and $response.ok){if(!$transport.WaitForExit(5000)){$transport.Terminate()};break}
            }
        }
        Start-Sleep -Milliseconds 50
    }
}catch{
    if(!$record){$record=@{schema=2;vmId=$state.id;sessionId=$SessionId;phase='failed'}}
    $record.phase='failed'
    $reason=$_.Exception.Message
    $record.failureReason=$reason.Substring(0,[Math]::Min(1024,$reason.Length))
    Write-VmJson $vm 'process.json' $record
    throw 'VM supervisor failed; inspect bounded stderr log'
}finally{
    if($transport){$transport.Dispose()}
    if($record -and $record.phase -ceq 'running'){$record.phase='exited';Write-VmJson $vm 'process.json' $record}
    if($lockStream){$lockStream.Dispose()}
}
