# Safe fixtures only. -QmpSmoke starts pinned, diskless machine=none, no OS.
param([switch]$QmpSmoke)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'driver-vm-common.ps1')
$originalRoot=$labSigningRoot
$fixture=New-LabPrivateDirectory (Join-Path $originalRoot ('artifacts/driver-test-signing/vm-tests-'+[Guid]::NewGuid().ToString('N')))
$script:checks=0
function Check([bool]$Condition,[string]$Name){$script:checks++;if(!$Condition){throw ('VM regression failed: '+$Name)};Write-Output ('Passed '+$Name)}
function Reject([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Check $failed $Name}
try{
    foreach($name in @('driver-vm-common.ps1','start-driver-vm.ps1','run-driver-vm.ps1','control-driver-vm.ps1')){
        $errors=$null;$tokens=$null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors) | Out-Null
        Check (!$errors) ('PowerShell parser '+$name)
    }
    Initialize-VmQmpTransport;Check ($null -ne ('VeyloLab.QmpProcess' -as [type])) 'redirected stdio transport compiles'
    $labSigningRoot=$fixture
    $base=Join-Path $fixture '.tools/driver-lab';$vm=Join-Path $base ('vm-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $vm -Force | Out-Null
    Set-Acl -LiteralPath $vm -AclObject (Get-Acl -LiteralPath $fixture)
    $metadata=Join-Path $vm 'vm.json';$disk=Join-Path $vm 'windows.qcow2'
    [IO.File]::WriteAllText($disk,'owned fixture; not a disk')
    $diskAcl=Get-Acl -LiteralPath $disk;$diskAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);Set-Acl -LiteralPath $disk -AclObject $diskAcl
    $identity=[ordered]@{schema=1;id=[Guid]::NewGuid().ToString('D');ownedBy='Veylo isolated driver lab';disk=$disk;iso=(Join-Path $base 'Windows11-IoT-LTSC-2024-eval.iso');seed=(Join-Path $fixture 'artifacts/driver-test-signing/seed');accelerator='tcg';hostSecurityChanged=$false;installed=$false}
    function Save-Identity {
        [IO.File]::WriteAllText($metadata,($identity | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $fileAcl=Get-Acl -LiteralPath $metadata;$fileAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);Set-Acl -LiteralPath $metadata -AclObject $fileAcl
    }
    Save-Identity
    Check ((Get-OwnedVm $vm).state.id -ceq $identity.id) 'owned canonical metadata accepted without launching'
    $old=$identity.id;$identity.id='invalid';Save-Identity;Reject {Get-OwnedVm $vm} 'malformed UUID rejected';$identity.id=$old
    $old=$identity.ownedBy;$identity.ownedBy='external';Save-Identity;Reject {Get-OwnedVm $vm} 'foreign VM ownership rejected';$identity.ownedBy=$old
    $identity.installed='false';Save-Identity;Reject {Get-OwnedVm $vm} 'nonboolean installed marker rejected';$identity.installed=$false
    $old=$identity.disk;$identity.disk=(Join-Path $fixture 'foreign.qcow2');Save-Identity;Reject {Get-OwnedVm $vm -VerifyInputs} 'arbitrary disk field rejected before any process';$identity.disk=$old;Save-Identity
    Reject {Get-OwnedVm ($vm+':stream')} 'ADS VM path rejected'
    $junction=Join-Path $base 'junction';New-Item -ItemType Junction -Path $junction -Target $vm | Out-Null
    Reject {Get-OwnedVm $junction} 'reparse VM path rejected'
    $acl=Get-Acl -LiteralPath $metadata;$weak=Get-Acl -LiteralPath $metadata
    $weak.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $metadata -AclObject $weak;Reject {Get-OwnedVm $vm} 'metadata readable by Everyone rejected';Set-Acl -LiteralPath $metadata -AclObject $acl
    $args=Get-VmArguments $vm ([pscustomobject]$identity)
    Check (($args -contains 'stdio') -and !($args -match 'tcp:') -and ($args -contains 'usb-storage,drive=seed,removable=on')) 'launcher has no TCP and uses removable private seed'
    Check ($args -contains 'order=c,once=d') 'fresh initial ISO boot allowed'
    Check ($args -contains '-no-reboot') 'guest reset exits for explicit cold disk resume'
    Write-VmJson $vm 'process.json' @{schema=2;phase='exited'}
    Reject {Get-VmArguments $vm ([pscustomobject]$identity)} 'repeat initial ISO boot rejected to prevent disk wipe'
    $args=Get-VmArguments $vm ([pscustomobject]$identity) -BootInstalled
    Check (($args -contains 'order=c') -and !($args -match 'media=cdrom')) 'explicit disk resume omits unattended ISO'
    $identity.installed=$true;$args=Get-VmArguments $vm ([pscustomobject]$identity)
    Check (($args -contains 'order=c') -and !($args -match 'once=d')) 'installed metadata automatically boots disk'
    $old=$identity.seed;$identity.seed+=' ,file=physical';Reject {Get-VmArguments $vm ([pscustomobject]$identity)} 'QEMU comma option injection rejected';$identity.seed=$old
    $session=[Guid]::NewGuid().ToString('N');$screen=Join-Path $vm 'screen.ppm'
    $request=[pscustomobject]@{schema=1;vmId=$identity.id;sessionId=$session;requestId=[Guid]::NewGuid().ToString('N');command='query-status';keys=@();createdUtc=[DateTimeOffset]::UtcNow.ToString('O')}
    Write-VmJson $vm 'command.json' $request
    $roundtrip=Read-VmJson $vm 'command.json'
    Check ($roundtrip.createdUtc -is [string] -and (Get-VmCommand $roundtrip $identity.id $session $screen).execute -ceq 'query-status') 'ISO timestamps retain string identity through IPC JSON'
    $processTime=[DateTime]::UtcNow.ToString('O')
    Write-VmJson $vm 'process.json' @{startTimeUtc=$processTime}
    Check ((Read-VmJson $vm 'process.json').startTimeUtc -ceq $processTime) 'process start timestamp survives JSON without date coercion'
    $held=[IO.File]::Open((Join-Path $vm 'process.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{
        Write-VmJson $vm 'process.json' @{startTimeUtc='replacement'}
        Check ((Read-VmJson $vm 'process.json').startTimeUtc -ceq 'replacement') 'atomic IPC replacement succeeds while previous generation is open'
    }finally{$held.Dispose()}
    Check ((Get-VmCommand $request $identity.id $session $screen).execute -ceq 'query-status') 'fixed query-status accepted'
    $request.command='human-monitor-command';Reject {Get-VmCommand $request $identity.id $session $screen} 'arbitrary QMP command rejected'
    $request.command='screendump';$request | Add-Member -NotePropertyName filename -NotePropertyValue 'C:\outside.ppm'
    Reject {Get-VmCommand $request $identity.id $session $screen} 'caller screenshot path rejected';$request.PSObject.Properties.Remove('filename')
    Check ((Get-VmCommand $request $identity.id $session $screen).arguments.filename -ceq $screen) 'screenshot filename derived from owned VM'
    $request.command='send-key';$request.keys=@('ctrl','alt','delete')
    Check ((Get-VmCommand $request $identity.id $session $screen).arguments.keys.Count -eq 3) 'allowlisted bounded keys accepted'
    $request.keys=@('untrusted-key');Reject {Get-VmCommand $request $identity.id $session $screen} 'arbitrary key rejected'
    $request.keys=@('a')*17;Reject {Get-VmCommand $request $identity.id $session $screen} 'oversized key chord rejected'
    $request.keys=@('a');$request.sessionId='stale';Reject {Get-VmCommand $request $identity.id $session $screen} 'foreign session rejected';$request.sessionId=$session
    $request.createdUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O');Reject {Get-VmCommand $request $identity.id $session $screen} 'expired command rejected'
    Reject {Write-VmJson $vm 'outside.json' @{schema=1}} 'arbitrary IPC filename rejected'
    [IO.File]::WriteAllText((Join-Path $vm 'command.json'),('x'*17000));Reject {Read-VmJson $vm 'command.json'} 'oversized IPC JSON rejected'
    if($QmpSmoke){
        $exe=Assert-LabPath (Join-Path $originalRoot '.tools/driver-lab/qemu/qemu-system-x86_64.exe') $originalRoot
        $lock=Get-Content -LiteralPath (Join-Path $originalRoot 'driver/lab.lock.json') -Raw | ConvertFrom-Json
        Check ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $lock.qemu.systemSha256) 'smoke uses pinned QEMU'
        $transport=$null
        try{
            $transport=[VeyloLab.QmpProcess]::new($exe,[string[]]@('-machine','none','-nodefaults','-display','none','-nic','none','-monitor','none','-serial','none','-qmp','stdio','-S'),(Join-Path $fixture 'smoke-stderr.log'))
            $status=Connect-VmQmp $transport
            Check (!$transport.HasExited -and $status.status -ceq 'prelaunch') 'diskless QMP handshake and HasExited confirmation'
            Check (@(Get-NetTCPConnection -OwningProcess $transport.Id -State Listen -ErrorAction SilentlyContinue).Count -eq 0) 'diskless QEMU exposes no TCP listener'
            Invoke-VmQmp $transport @{execute='quit';id='smoke-quit'} | Out-Null
            Check ($transport.WaitForExit(5000)) 'QMP quit and termination cleanup bounded'
        }finally{if($transport){$transport.Dispose()}}
    }
    Write-Output ('VM tests Passed: '+$script:checks+'; real Windows VM not started')
}finally{$labSigningRoot=$originalRoot}
