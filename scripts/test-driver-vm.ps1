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
    foreach($name in @('prepare-driver-vm.ps1','driver-vm-common.ps1','start-driver-vm.ps1','run-driver-vm.ps1','control-driver-vm.ps1','stage-driver-acceptance.ps1','driver-vm-acceptance.ps1','stage-driver-version-transition.ps1','driver-vm-version-transition.ps1')){
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
    New-LabPrivateDirectory $identity.seed | Out-Null
    [IO.File]::WriteAllText($identity.iso,'inert fixed ISO fixture; never booted')
    function Save-Identity {
        [IO.File]::WriteAllText($metadata,($identity | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $fileAcl=Get-Acl -LiteralPath $metadata;$fileAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);Set-Acl -LiteralPath $metadata -AclObject $fileAcl
    }
    Save-Identity
    Check ((Get-OwnedVm $vm).state.id -ceq $identity.id) 'owned canonical metadata accepted without launching'
    $old=$identity.id;$identity.id='invalid';Save-Identity;Reject {Get-OwnedVm $vm} 'malformed UUID rejected';$identity.id=$old
    $old=$identity.ownedBy;$identity.ownedBy='external';Save-Identity;Reject {Get-OwnedVm $vm} 'foreign VM ownership rejected';$identity.ownedBy=$old
    $identity.installed='false';Save-Identity;Reject {Get-OwnedVm $vm} 'nonboolean installed marker rejected';$identity.installed=$false
    Save-Identity
    Check ((Get-VmFirmwarePaths $vm ([pscustomobject]$identity)).firmware -ceq 'BIOS') 'legacy metadata defaults to BIOS without flash attachments'
    $biosArgs=Get-VmArguments $vm ([pscustomobject]$identity)
    Check (!($biosArgs -match 'if=pflash')) 'legacy BIOS launch has no pflash drive'
    $identity.firmware='BIOS';Save-Identity
    Check ((Get-OwnedVm $vm).state.firmware -ceq 'BIOS') 'explicit BIOS metadata accepted'
    $biosLayout=Get-VmInstallLayout -Firmware BIOS
    [xml]$biosXml=('<Disk xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><CreatePartitions>'+$biosLayout.create+'</CreatePartitions><ModifyPartitions>'+$biosLayout.modify+'</ModifyPartitions></Disk>')
    Check ($biosLayout.partitionId -eq 1 -and $biosXml.Disk.CreatePartitions.CreatePartition.Type -ceq 'Primary' -and
        $biosXml.Disk.ModifyPartitions.ModifyPartition.Active -ceq 'true') 'BIOS unattend preserves primary active Windows partition one'
    $uefiLayout=Get-VmInstallLayout -Firmware UEFI
    [xml]$uefiXml=('<Disk xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><CreatePartitions>'+$uefiLayout.create+'</CreatePartitions><ModifyPartitions>'+$uefiLayout.modify+'</ModifyPartitions></Disk>')
    $partitions=@($uefiXml.Disk.CreatePartitions.CreatePartition);$modify=@($uefiXml.Disk.ModifyPartitions.ModifyPartition)
    Check ($uefiLayout.partitionId -eq 3 -and $partitions.Count -eq 3 -and $partitions[0].Type -ceq 'EFI' -and
        $partitions[0].Size -ceq '300' -and $partitions[1].Type -ceq 'MSR' -and $partitions[1].Size -ceq '16' -and
        $partitions[2].Type -ceq 'Primary' -and $partitions[2].Extend -ceq 'true' -and $modify.Count -eq 2 -and
        $modify[0].PartitionID -ceq '1' -and $modify[0].Format -ceq 'FAT32' -and $modify[1].PartitionID -ceq '3' -and
        $modify[1].Format -ceq 'NTFS' -and !($uefiLayout.modify -match '<Active>')) 'UEFI unattend uses GPT EFI300 FAT32 MSR16 and remaining NTFS Windows partition three'
    # Expand only the saved XML string AST with an inert guest password. Never
    # execute preparation, qemu-img, WDK discovery, mount or partition commands.
    $prepareAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'prepare-driver-vm.ps1'),[ref]$null,[ref]$null)
    $xmlTemplate=$prepareAst.Find({param($node) $node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $node.Extent.Text.Contains('<unattend ')},$true)
    if(!$xmlTemplate){throw 'Missing guest unattend XML template'}
    $password='inert guest fixture; never used'
    foreach($mode in @('BIOS','UEFI')){
        $layout=Get-VmInstallLayout -Firmware $mode
        [xml]$unattend=& ([ScriptBlock]::Create($xmlTemplate.Extent.Text))
        $manager=[Xml.XmlNamespaceManager]::new($unattend.NameTable);$manager.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        $target=$unattend.SelectSingleNode('//u:InstallTo/u:PartitionID',$manager)
        $creates=$unattend.SelectNodes('//u:CreatePartitions/u:CreatePartition',$manager)
        Check ($target.InnerText -ceq [string]$layout.partitionId -and $creates.Count -eq $(if($mode -ceq 'UEFI'){3}else{1}) -and
            $unattend.SelectSingleNode('//u:DiskID',$manager).InnerText -ceq '0' -and
            ($mode -ceq 'BIOS' -or $creates[0].Size -ceq '300')) ('actual saved unattend template maps new disk zero to '+$mode+' Windows partition')
    }
    $password=$null
    Reject {Get-VmInstallLayout -Firmware 'foreign'} 'unknown guest install firmware rejected'
    $code=Join-Path $base 'qemu/share/edk2-x86_64-code.fd';New-Item -ItemType Directory -Path (Split-Path $code -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($code,'inert firmware fixture; never booted')
    $vars=Join-Path $vm 'uefi-vars.fd'
    $varsStream=[IO.File]::Open($vars,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    try{$varsStream.SetLength(540672)}finally{$varsStream.Dispose()}
    $varsAcl=Get-Acl -LiteralPath $vars;$varsAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);Set-Acl -LiteralPath $vars -AclObject $varsAcl
    $firmwareLockPath=Join-Path $fixture 'driver/lab.lock.json';New-Item -ItemType Directory -Path (Split-Path $firmwareLockPath -Parent) -Force | Out-Null
    $firmwareLock=@{qemu=@{uefiCodeSha256=(Get-FileHash -LiteralPath $code -Algorithm SHA256).Hash.ToLowerInvariant()}}
    function Save-FirmwareLock {$firmwareLock | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $firmwareLockPath -Encoding utf8}
    Save-FirmwareLock
    $identity.firmware='UEFI';$identity.firmwareCode=$code;$identity.firmwareVars=$vars;Save-Identity
    Check ((Get-OwnedVm $vm).state.firmware -ceq 'UEFI') 'owned UEFI metadata paths validated without input hashing'
    Check ((Get-VmFirmwarePaths $vm ([pscustomobject]$identity) -VerifyInputs).code -ceq $code) 'UEFI immutable code pin verified against inert fixture lock'
    $uefiArgs=Get-VmArguments $vm ([pscustomobject]$identity)
    $flash=@($uefiArgs | Where-Object {$_ -match 'if=pflash'})
    Check ($flash.Count -eq 2 -and $flash[0] -ceq ('file='+$code+',format=raw,if=pflash,unit=0,readonly=on') -and
        $flash[1] -ceq ('file='+$vars+',format=raw,if=pflash,unit=1')) 'UEFI launch attaches only exact readonly code and owned writable NVRAM'
    $old=$identity.firmwareVars;$identity.firmwareVars=Join-Path $fixture 'foreign-vars.fd';Save-Identity
    Reject {Get-OwnedVm $vm} 'foreign NVRAM path rejected even without VerifyInputs'
    Reject {Get-VmArguments $vm ([pscustomobject]$identity)} 'foreign NVRAM path cannot become a QEMU argument';$identity.firmwareVars=$old
    $old=$identity.firmwareCode;$identity.firmwareCode=Join-Path $fixture 'foreign-code.fd';Save-Identity
    Reject {Get-OwnedVm $vm} 'foreign firmware code rejected even without VerifyInputs'
    Reject {Get-VmArguments $vm ([pscustomobject]$identity)} 'foreign firmware code cannot become a QEMU argument';$identity.firmwareCode=$old
    foreach($field in @('firmwareCode','firmwareVars')){
        $old=$identity[$field];$identity.Remove($field);Save-Identity
        Reject {Get-OwnedVm $vm} ('missing UEFI metadata field rejected '+$field);$identity[$field]=$old
    }
    $identity.firmware='unexpected';Save-Identity;Reject {Get-OwnedVm $vm} 'unknown firmware enum rejected';$identity.firmware='UEFI';Save-Identity
    $old=$firmwareLock.qemu.uefiCodeSha256;$firmwareLock.qemu.uefiCodeSha256='bad';Save-FirmwareLock
    Reject {Get-VmFirmwarePaths $vm ([pscustomobject]$identity) -VerifyInputs} 'malformed UEFI code pin rejected'
    $firmwareLock.qemu.uefiCodeSha256=('0'*64);Save-FirmwareLock
    Reject {Get-VmFirmwarePaths $vm ([pscustomobject]$identity) -VerifyInputs} 'mismatched UEFI code hash rejected';$firmwareLock.qemu.uefiCodeSha256=$old;Save-FirmwareLock
    $codeBytes=[IO.File]::ReadAllBytes($code);$stream=[IO.File]::Open($code,[IO.FileMode]::Open,[IO.FileAccess]::Write)
    try{$stream.SetLength(16MB+1)}finally{$stream.Dispose()}
    Reject {Get-OwnedVm $vm} 'oversized firmware code rejected without VerifyInputs';[IO.File]::WriteAllBytes($code,$codeBytes)
    $codeBackup=Join-Path (Split-Path $code -Parent) 'fixture-code-backup.fd';Move-Item -LiteralPath $code -Destination $codeBackup
    try{
        New-Item -ItemType Junction -Path $code -Target $vm | Out-Null
        Reject {Get-OwnedVm $vm} 'reparse firmware code rejected without VerifyInputs'
    }finally{if(Test-Path -LiteralPath $code){[IO.Directory]::Delete($code)};Move-Item -LiteralPath $codeBackup -Destination $code}
    $stream=[IO.File]::Open($vars,[IO.FileMode]::Open,[IO.FileAccess]::Write)
    try{$stream.SetLength(16MB+1)}finally{$stream.Dispose()}
    Reject {Get-OwnedVm $vm} 'oversized owned NVRAM rejected without VerifyInputs'
    $stream=[IO.File]::Open($vars,[IO.FileMode]::Open,[IO.FileAccess]::Write)
    try{$stream.SetLength(540671)}finally{$stream.Dispose()}
    Reject {Get-OwnedVm $vm} 'wrong NVRAM flash size rejected'
    $stream=[IO.File]::Open($vars,[IO.FileMode]::Open,[IO.FileAccess]::Write)
    try{$stream.SetLength(540672)}finally{$stream.Dispose()}
    $varsBackup=Join-Path $vm 'fixture-vars-backup.fd';Move-Item -LiteralPath $vars -Destination $varsBackup
    try{
        New-Item -ItemType Junction -Path $vars -Target $vm | Out-Null
        Reject {Get-OwnedVm $vm} 'reparse NVRAM rejected without VerifyInputs'
    }finally{if(Test-Path -LiteralPath $vars){[IO.Directory]::Delete($vars)};Move-Item -LiteralPath $varsBackup -Destination $vars}
    $weak=Get-Acl -LiteralPath $vars;$weak.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $vars -AclObject $weak;Reject {Get-OwnedVm $vm} 'public-readable NVRAM rejected without VerifyInputs';Set-Acl -LiteralPath $vars -AclObject $varsAcl
    $identity.firmware='BIOS';Save-Identity;Reject {Get-OwnedVm $vm} 'BIOS metadata cannot retain arbitrary flash attachments'
    $identity.Remove('firmwareCode');$identity.Remove('firmwareVars');$identity.Remove('firmware');Save-Identity
    Check ((Get-OwnedVm $vm).state.installed -eq $false) 'legacy BIOS fixture remains valid after isolated UEFI checks'
    $old=$identity.disk;$identity.disk=Join-Path $fixture 'foreign-disk.qcow2';Save-Identity
    Reject {Get-OwnedVm $vm} 'control-only ownership read rejects foreign disk metadata';$identity.disk=$old
    $old=$identity.seed;$identity.seed=$fixture;Save-Identity
    Reject {Get-OwnedVm $vm} 'control-only ownership read rejects seed outside private seed root';$identity.seed=$old
    $old=$identity.iso;$identity.iso=Join-Path $fixture 'foreign.iso';Save-Identity
    Reject {Get-OwnedVm $vm} 'control-only ownership read rejects foreign ISO metadata';$identity.iso=$old;Save-Identity
    $acceptanceSeed=New-LabPrivateDirectory (Join-Path $fixture 'artifacts/driver-test-signing/acceptance-fixture')
    $acceptance=New-LabPrivateDirectory (Join-Path $acceptanceSeed 'acceptance')
    $acceptanceFiles=[ordered]@{}
    foreach($name in @('driver-vm-acceptance.ps1','ses_driver_capture_lab_tests.exe')){
        $file=Join-Path $acceptance $name
        [IO.File]::WriteAllText($file,'inert owned acceptance fixture; never executed')
        # An elevated Windows token may default new files to Administrators.
        # Match the existing disk/metadata fixtures without relaxing the guard.
        $fileAcl=Get-Acl -LiteralPath $file;$fileAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);Set-Acl -LiteralPath $file -AclObject $fileAcl
        $acceptanceFiles[$name]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $acceptanceManifest=Join-Path $acceptance 'acceptance-manifest.json'
    function Save-Acceptance {
        @{schema=1;testOnly=$true;vmId=$identity.id;files=$acceptanceFiles} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $acceptanceManifest -Encoding utf8
        $fileAcl=Get-Acl -LiteralPath $acceptanceManifest;$fileAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);Set-Acl -LiteralPath $acceptanceManifest -AclObject $fileAcl
    }
    Save-Acceptance
    Check ((Assert-VmAcceptanceSeed $acceptanceSeed $identity.id) -eq $acceptance) 'fixed private acceptance seed hash inventory accepted'
    $versionDirectory=New-LabPrivateDirectory (Join-Path $acceptanceSeed 'version-transition')
    $versionFiles=[ordered]@{}
    $packageNames=@('SesMicrophone.inf','SesMicrophone.sys','SesMicrophone.cat','lab-test.cer','ses_driver_capture_lab_tests.exe','test-signing-manifest.json')
    foreach($version in @('old','current')){
        New-LabPrivateDirectory (Join-Path $versionDirectory $version) | Out-Null
        foreach($name in $packageNames){$versionFiles[$version+'\'+$name]=''}
    }
    $versionFiles['driver-vm-version-transition.ps1']=''
    foreach($name in @($versionFiles.Keys)){
        $file=Join-Path $versionDirectory $name
        [IO.File]::WriteAllText($file,'inert version fixture; no executable or certificate')
        $fileAcl=Get-Acl -LiteralPath $file;$fileAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);Set-Acl -LiteralPath $file -AclObject $fileAcl
        $versionFiles[$name]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $versionIdentity=@{schema=1;vmId=$identity.id;testOnly=$true;productionReady=$false;oldVersion='0.5.0.0';currentVersion='0.5.1.0';abi=5;protocol=1;files=$versionFiles}
    $versionManifest=Join-Path $versionDirectory 'version-transition-manifest.json'
    function Save-VersionFixture {
        $versionIdentity | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $versionManifest -Encoding utf8
        $fileAcl=Get-Acl -LiteralPath $versionManifest;$fileAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User);Set-Acl -LiteralPath $versionManifest -AclObject $fileAcl
    }
    Save-VersionFixture
    Check ((Assert-VmVersionTransitionPayload $versionDirectory $identity.id) -ceq $versionDirectory) 'bounded version payload accepted without executing files'
    Reject {Assert-VmVersionTransitionPayload $versionDirectory ([Guid]::NewGuid().ToString('D'))} 'foreign version payload VM rejected'
    foreach($case in @(@{name='schema';value=2},@{name='testOnly';value='true'},@{name='productionReady';value=$true},@{name='oldVersion';value='0.5.1.0'},@{name='abi';value=4})){
        $original=$versionIdentity[$case.name];$versionIdentity[$case.name]=$case.value;Save-VersionFixture
        Reject {Assert-VmVersionTransitionPayload $versionDirectory $identity.id} ('version payload invalid contract '+$case.name)
        $versionIdentity[$case.name]=$original
    }
    $original=$versionFiles['old\SesMicrophone.sys'];$versionFiles['old\SesMicrophone.sys']='0'*64;Save-VersionFixture
    Reject {Assert-VmVersionTransitionPayload $versionDirectory $identity.id} 'version payload checksum corruption rejected'
    $versionFiles['old\SesMicrophone.sys']=$original
    $versionFiles.Remove('old\SesMicrophone.sys');$versionFiles['old/SesMicrophone.sys']=$original;Save-VersionFixture
    Reject {Assert-VmVersionTransitionPayload $versionDirectory $identity.id} 'version payload alternate separator rejected'
    $versionFiles.Remove('old/SesMicrophone.sys');$versionFiles['old\SesMicrophone.sys']=$original
    $versionFiles['../foreign']='0'*64;Save-VersionFixture
    Reject {Assert-VmVersionTransitionPayload $versionDirectory $identity.id} 'version payload traversal entry rejected'
    $versionFiles.Remove('../foreign');Save-VersionFixture
    $extra=Join-Path $versionDirectory 'foreign.ps1';[IO.File]::WriteAllText($extra,'inert')
    Reject {Assert-VmVersionTransitionPayload $versionDirectory $identity.id} 'version payload root extras rejected'
    Remove-Item -LiteralPath $extra
    $weak=Get-Acl -LiteralPath $versionManifest;$originalAcl=$weak
    $weak.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $versionManifest -AclObject $weak
    Reject {Assert-VmVersionTransitionPayload $versionDirectory $identity.id} 'version payload public-readable manifest rejected'
    Set-Acl -LiteralPath $versionManifest -AclObject (Get-Acl -LiteralPath (Join-Path $versionDirectory 'driver-vm-version-transition.ps1'))
    # Extract only the pure ACL guard; never execute the guest runner on host.
    $guestAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'driver-vm-acceptance.ps1'),[ref]$null,[ref]$null)
    # Only the pure report decision enters this runspace; no guest runner,
    # driver, device, certificate, registry or host audio is accessed.
    $captureDefinition=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-CaptureReport'},$true)
    if(!$captureDefinition){throw 'Missing capture report decision.'}
    $captureOptionGuards=($guestAst.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
        ($node.Extent.Text.Contains("throw 'Capture options are valid only in Capture mode.'") -or
         $node.Extent.Text.Contains("throw 'KernelDiagnostics requires Extended and ProductBridge.'"))},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"
    if(!$captureOptionGuards){throw 'Missing capture option guards.'}
    $captureRunspace=[PowerShell]::Create()
    try{
        $null=$captureRunspace.AddScript({param($helper,$optionGuards)
            $ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
            . ([ScriptBlock]::Create($helper))
            function New-InertCapture {
                return @{schema=1;checks=33;failures=0;unsupported=0;verified_endpoints=1;formats_passed=2;self_tests=0;
                    extended_kernel_capture=@{requested=$true;ran=$true;mode='production_driver_bridge';requested_seconds=60;elapsed_ms=60000;
                        product_bridge=@{requested=$true;ran=$true;source='native/src/driver_bridge.hpp';worker_mmcss_pro_audio=$true;
                            queue_drops=0;submitted_packets=5896;source_sessions=3;last_observed_status=2;last_observed_error=0}}}
            }
            function Emit-Capture([bool]$Passed,[string]$Name){[pscustomobject]@{passed=$Passed;name=$Name}}
            function New-InertDiagnosticCapture([bool]$Requested=$true){
                $report=New-InertCapture
                $diagnostics=@{requested=$Requested;mode='optional_instrumented_driver_bridge';
                    source='SES_IOCTL_DIAGNOSTICS_on_production_worker_owner_handle';clock='interrupt_time_100ns';
                    scope='kernel_trace_connected_source_sessions';first_underrun_counter_scope='original_ring_lifetime_counters';
                    timing_effect='additional_bounded_ioctls_on_first_underrun_and_each_source_session_end_or_failure';
                    not_audio_latency=$true;query_deadline_ms=100;record_capacity=3;record_count=0;records=@();first_failure_record=$null}
                if($Requested){
                    $diagnostics.record_count=3
                    foreach($session in 1..3){
                        $data=@{}
                        foreach($field in @('version','size','capture_calls','total_requested_frames','max_capture_frames','max_pull_chunk_frames',
                            'last_capture_queued_before','last_capture_queued_after','last_capture_frames','reserved0','last_capture_tick_hns',
                            'last_successful_write_tick_hns','last_successful_write_gap_hns','max_successful_write_gap_hns',
                            'first_underrun_present','first_underrun_queued_before','first_underrun_chunk_frames','first_underrun_remaining_frames',
                            'first_underrun_capture_frames','first_underrun_old_count','first_underrun_new_count','reserved1',
                            'first_underrun_tick_hns','first_underrun_since_successful_write_hns','first_underrun_successful_write_tick_hns',
                            'first_underrun_received_frames','first_underrun_silence_before','first_underrun_silence_after')){$data[$field]=0}
                        $data.version=1;$data.size=160;$data.capture_calls=100;$data.total_requested_frames=4800
                        $data.max_capture_frames=960;$data.max_pull_chunk_frames=480;$data.last_capture_frames=48
                        $diagnostics.records+=@{source_session=$session;available=$true;query_error=0;data=$data}
                    }
                }
                $report.extended_kernel_capture.product_bridge.kernel_diagnostics=$diagnostics
                return $report
            }
            Emit-Capture (Test-CaptureReport (New-InertCapture) $true 60 $true) 'product bridge complete report accepted'
            $strict=New-InertCapture;$strict.extended_kernel_capture.mode='strict_synthetic_producer'
            Emit-Capture (Test-CaptureReport $strict $true 60 $false) 'strict producer complete report accepted'
            Emit-Capture (!(Test-CaptureReport $strict $true 60 $true)) 'strict report cannot satisfy product request'
            Emit-Capture (!(Test-CaptureReport (New-InertCapture) $true 60 $false)) 'product report cannot satisfy strict request'
            Emit-Capture (Test-CaptureReport (New-InertCapture) $false 60 $false) 'ordinary capture base evidence accepted'
            Emit-Capture (!(Test-CaptureReport (New-InertCapture) $false 60 $true)) 'product without extended rejected'
            Emit-Capture (!(Test-CaptureReport $null $true 60 $true)) 'missing report rejected'
            foreach($field in @('schema','checks','failures','unsupported','verified_endpoints','formats_passed','self_tests')){
                $report=New-InertCapture;$report[$field]=99
                if($field -ceq 'checks'){$report[$field]=0}
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) ('invalid base '+$field)
            }
            foreach($change in @(@{key='requested';value=$false},@{key='ran';value=$false},@{key='mode';value='other'},
                @{key='requested_seconds';value=59},@{key='elapsed_ms';value=59999},@{key='elapsed_ms';value=61001})){
                $report=New-InertCapture;$report.extended_kernel_capture[$change.key]=$change.value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) ('invalid extended '+$change.key+'='+$change.value)
            }
            foreach($change in @(@{key='requested';value=$false},@{key='ran';value=$false},@{key='source';value='copy'},
                @{key='worker_mmcss_pro_audio';value=$false},@{key='queue_drops';value=1},@{key='submitted_packets';value=0},
                @{key='source_sessions';value=2},@{key='last_observed_status';value=6},@{key='last_observed_error';value=1460})){
                $report=New-InertCapture;$report.extended_kernel_capture.product_bridge[$change.key]=$change.value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) ('invalid bridge '+$change.key)
            }
            foreach($field in @('requested','ran','source','worker_mmcss_pro_audio','queue_drops','submitted_packets','source_sessions','last_observed_status','last_observed_error')){
                $report=New-InertCapture;$report.extended_kernel_capture.product_bridge.Remove($field)
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) ('missing bridge '+$field)
            }
            foreach($value in @(@(0,0),'0',0.0,-1,$null,$true)){
                foreach($field in @('failures','checks')){
                    $report=New-InertCapture;$report[$field]=$value
                    Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) ('malformed base scalar '+$field)
                }
                foreach($field in @('queue_drops','submitted_packets','source_sessions')){
                    $report=New-InertCapture;$report.extended_kernel_capture.product_bridge[$field]=$value
                    Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) ('malformed bridge scalar '+$field)
                }
                $report=New-InertCapture;$report.extended_kernel_capture.elapsed_ms=$value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) 'malformed measured duration scalar'
            }
            foreach($value in @('true',1,@($true,$true),$null)){
                $report=New-InertCapture;$report.extended_kernel_capture.product_bridge.worker_mmcss_pro_audio=$value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) 'malformed MMCSS boolean'
            }
            $report=New-InertCapture;$report.extended_kernel_capture.product_bridge.source_sessions=99
            Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) 'extra owner sessions cannot satisfy exact lifecycle'
            Emit-Capture (Test-CaptureReport (New-InertDiagnosticCapture) $true 60 $true $true) 'instrumented three ordered owner sessions accepted'
            Emit-Capture (Test-CaptureReport (New-InertDiagnosticCapture $false) $true 60 $true) 'explicit noninstrumented current report accepted'
            Emit-Capture (!(Test-CaptureReport (New-InertCapture) $true 60 $true $true)) 'legacy report cannot satisfy diagnostic request'
            Emit-Capture (!(Test-CaptureReport (New-InertDiagnosticCapture) $true 60 $true)) 'instrumented report cannot satisfy ordinary product acceptance'
            Emit-Capture (!(Test-CaptureReport (New-InertDiagnosticCapture) $false 60 $false)) 'instrumented report cannot satisfy ordinary base acceptance'
            Emit-Capture (!(Test-CaptureReport (New-InertDiagnosticCapture) $true 60 $false $true)) 'diagnostics require product mode'
            Emit-Capture (!(Test-CaptureReport (New-InertDiagnosticCapture) $false 60 $true $true)) 'diagnostics require extended mode'
            Emit-Capture (!(Test-CaptureReport (New-InertDiagnosticCapture $false) $true 60 $true $true)) 'diagnostics requested flag must match invocation'
            foreach($value in @($null,$true,'diagnostics',@(@{requested=$true},@{requested=$true}))){
                $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics=$value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) 'diagnostic envelope must be one actual object'
            }
            foreach($count in 2,4){
                $report=New-InertDiagnosticCapture;$diag=$report.extended_kernel_capture.product_bridge.kernel_diagnostics
                $diag.records=if($count -eq 2){@($diag.records[0],$diag.records[1])}else{@($diag.records)+@($diag.records[2])}
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) 'actual diagnostic array must contain exactly three records'
            }
            $report=New-InertDiagnosticCapture;$diag=$report.extended_kernel_capture.product_bridge.kernel_diagnostics
            $diag.records=@($diag.records[1],$diag.records[0],$diag.records[2])
            Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) 'reordered diagnostic owner sessions rejected'
            foreach($field in @('requested','mode','source','clock','scope','first_underrun_counter_scope','timing_effect','not_audio_latency',
                'query_deadline_ms','record_capacity','record_count','records','first_failure_record')){
                $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.Remove($field)
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) ('missing diagnostic envelope '+$field)
            }
            foreach($case in @(@{field='requested';value='true'},@{field='requested';value=$false},@{field='mode';value='normal'},
                @{field='source';value='foreign'},@{field='clock';value='qpc_100ns'},@{field='scope';value='unknown'},
                @{field='first_underrun_counter_scope';value='session_counters'},@{field='timing_effect';value='none'},
                @{field='not_audio_latency';value='true'},@{field='not_audio_latency';value=$false},@{field='not_audio_latency';value=1},
                @{field='query_deadline_ms';value=101},@{field='record_capacity';value=4},@{field='record_count';value=2},
                @{field='record_count';value=4},@{field='records';value=@()},@{field='records';value='records'},
                @{field='records';value=@{source_session=1}},@{field='records';value=$null})){
                $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics[$case.field]=$case.value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) ('invalid diagnostic envelope '+$case.field)
            }
            foreach($case in @(@{field='source_session';value=2},@{field='source_session';value=0},@{field='available';value=$false},
                @{field='available';value='true'},@{field='available';value=1},@{field='query_error';value=50},@{field='query_error';value='0'},
                @{field='data';value=@()},@{field='data';value=$null})){
                $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.records[0][$case.field]=$case.value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) ('invalid diagnostic record '+$case.field)
            }
            foreach($field in @('source_session','available','query_error','data')){
                $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.records[0].Remove($field)
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) ('missing diagnostic record '+$field)
            }
            $fields=@((New-InertDiagnosticCapture).extended_kernel_capture.product_bridge.kernel_diagnostics.records[0].data.Keys)
            foreach($field in $fields){
                $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.records[0].data.Remove($field)
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) ('missing diagnostic scalar '+$field)
                foreach($value in @(@(0,0),'0',0.0,-1,$null,$true)){
                    $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.records[0].data[$field]=$value
                    Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) ('malformed diagnostic scalar '+$field)
                }
            }
            foreach($case in @(@{field='version';value=2},@{field='size';value=48},@{field='reserved0';value=1},@{field='reserved1';value=1},
                @{field='first_underrun_present';value=2},@{field='max_pull_chunk_frames';value=481},@{field='max_capture_frames';value=[uint64]4294967296},
                @{field='last_capture_queued_before';value=4097},@{field='last_capture_queued_after';value=4097},@{field='last_capture_frames';value=961})){
                $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.records[0].data[$case.field]=$case.value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) ('invalid diagnostic bounds '+$case.field)
            }
            $report=New-InertDiagnosticCapture;$data=$report.extended_kernel_capture.product_bridge.kernel_diagnostics.records[0].data
            $data.max_capture_frames=[uint32]::MaxValue;$data.last_capture_frames=100000
            Emit-Capture (Test-CaptureReport $report $true 60 $true $true) 'large original capture requests remain legitimate diagnostic evidence'
            function New-FirstFailureCapture {
                $report=New-InertDiagnosticCapture;$diag=$report.extended_kernel_capture.product_bridge.kernel_diagnostics
                $data=$diag.records[1].data;$data.first_underrun_present=1;$data.first_underrun_chunk_frames=48
                $data.first_underrun_remaining_frames=48;$data.first_underrun_capture_frames=48;$data.first_underrun_new_count=1
                $diag.first_failure_record=($diag.records[1] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable)
                return $report
            }
            Emit-Capture (!(Test-CaptureReport (New-FirstFailureCapture) $true 60 $true $true)) 'valid retained terminal first-underrun context cannot pass healthy capture acceptance'
            foreach($case in @(@{field='first_underrun_queued_before';value=4097},@{field='first_underrun_chunk_frames';value=0},
                @{field='first_underrun_chunk_frames';value=481},@{field='first_underrun_remaining_frames';value=47},
                @{field='first_underrun_capture_frames';value=47},@{field='first_underrun_new_count';value=0})){
                $report=New-FirstFailureCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.records[1].data[$case.field]=$case.value
                Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) ('invalid first-underrun geometry '+$case.field)
            }
            $report=New-FirstFailureCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.first_failure_record=$null
            Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) 'missing retained first failure rejected'
            $report=New-FirstFailureCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.first_failure_record.data.first_underrun_tick_hns=99
            Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) 'mismatched retained first-failure context rejected'
            $report=New-InertDiagnosticCapture;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.first_failure_record=@{source_session=1}
            Emit-Capture (!(Test-CaptureReport $report $true 60 $true $true)) 'fabricated first-failure record rejected'
            $report=New-InertDiagnosticCapture $false;$report.extended_kernel_capture.product_bridge.kernel_diagnostics.record_count=1
            Emit-Capture (!(Test-CaptureReport $report $true 60 $true)) 'unrequested instrumented record count rejected'
            foreach($case in @(@{mode='Capture';extended=$true;product=$true;diag=$true;pass=$true},
                @{mode='Capture';extended=$false;product=$true;diag=$true;pass=$false},
                @{mode='Capture';extended=$true;product=$false;diag=$true;pass=$false},
                @{mode='Diagnostics';extended=$true;product=$true;diag=$true;pass=$false},
                @{mode='Capture';extended=$false;product=$false;diag=$false;pass=$true})){
                $Mode=$case.mode;$Extended=$case.extended;$ProductBridge=$case.product;$KernelDiagnostics=$case.diag;$PSBoundParameters=@{}
                $allowed=$true;try{& ([ScriptBlock]::Create($optionGuards))}catch{$allowed=$false}
                Emit-Capture ($allowed -eq $case.pass) 'extracted diagnostic option guards enforce exact mode combinations'
            }
        }).AddArgument($captureDefinition.Extent.Text).AddArgument($captureOptionGuards)
        $captureResults=@($captureRunspace.Invoke())
        if($captureRunspace.Streams.Error.Count -gt 0 -or $captureResults.Count -ne 362){throw ('Capture report fixtures failed: count='+$captureResults.Count+' errors='+($captureRunspace.Streams.Error | Out-String))}
        foreach($captureResult in $captureResults){Check $captureResult.passed ('inert capture report '+$captureResult.name)}
    }finally{$captureRunspace.Dispose()}
    $stopDefinition=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Stop-BoundedGuestChild'},$true)
    if(!$stopDefinition){throw 'Missing bounded child stop helper.'}
    $stopRunspace=[PowerShell]::Create()
    try{
        $null=$stopRunspace.AddScript({param($helper)
            $ErrorActionPreference='Stop'
            . ([ScriptBlock]::Create($helper))
            foreach($case in @('exited','running','exit-race','live-error')){
                $mock=[pscustomobject]@{case=$case;exited=($case -ceq 'exited');kills=0}
                $mock | Add-Member -MemberType ScriptProperty -Name HasExited -Value {return $this.exited}
                $mock | Add-Member -MemberType ScriptMethod -Name Kill -Value {
                    $this.kills++
                    if($this.case -ceq 'live-error'){throw 'inert live child kill failure'}
                    $this.exited=$true
                    if($this.case -ceq 'exit-race'){throw 'inert child already exited'}
                }
                $threw=$false;try{Stop-BoundedGuestChild $mock}catch{$threw=$true}
                [pscustomobject]@{name=$case;passed=($threw -eq ($case -ceq 'live-error') -and
                    $mock.kills -eq $(if($case -ceq 'exited'){0}else{1}) -and
                    $mock.exited -eq ($case -cne 'live-error'))}
            }
        }).AddArgument($stopDefinition.Extent.Text)
        $stopResults=@($stopRunspace.Invoke())
        if($stopRunspace.Streams.Error.Count -gt 0 -or $stopResults.Count -ne 4){throw 'Bounded child stop fixtures failed.'}
        foreach($stopResult in $stopResults){Check $stopResult.passed ('inert bounded child '+$stopResult.name)}
    }finally{$stopRunspace.Dispose()}
    # Only the pure identity validator and its assertion wrapper execute. The
    # device inventory is mocked; no host CIM, driver or DevCon is accessed.
    $deviceIdentitySource=(@('Test-SesDeviceIdentity','Assert-OneSesDevice') | ForEach-Object {
        $wanted=$_
        $definition=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wanted},$true)
        if(!$definition){throw ('Missing device identity helper '+$wanted)}
        $definition.Extent.Text
    }) -join "`r`n"
    $identityRunspace=[PowerShell]::Create()
    try{
        $null=$identityRunspace.AddScript({param($helpers)
            $ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
            . ([ScriptBlock]::Create($helpers))
            function Get-CimInstance {throw 'Device identity fixtures must never query host devices.'}
            function devcon.exe {throw 'Device identity fixtures must never invoke DevCon.'}
            function Get-SesDevices {return $script:identityDevices}
            function Make-Device([string]$Id='ROOT\MEDIA\0000',[string]$Service='SesMicrophone',$Hardware=@('ROOT\SES_MICROPHONE')){
                return [pscustomobject]@{DeviceID=$Id;Service=$Service;HardwareID=$Hardware;ConfigManagerErrorCode=0}
            }
            $real=Make-Device
            foreach($case in @(
                @{name='actual DevCon root audio instance';devices=@($real);expected=$true},
                @{name='known direct root instance';devices=@(Make-Device 'ROOT\SES_MICROPHONE\0001');expected=$true},
                @{name='case-insensitive Windows identity';devices=@(Make-Device 'root\media\0002' 'sesmicrophone' @('root\ses_microphone'));expected=$true},
                @{name='foreign hardware ID';devices=@(Make-Device -Hardware @('ROOT\OTHER'));expected=$false},
                @{name='hardware prefix masquerade';devices=@(Make-Device -Hardware @('ROOT\SES_MICROPHONE_EXTRA'));expected=$false},
                @{name='hardware wildcard';devices=@(Make-Device -Hardware @('ROOT\SES_MICROPHONE*'));expected=$false},
                @{name='duplicate hardware identity';devices=@(Make-Device -Hardware @('ROOT\SES_MICROPHONE','ROOT\SES_MICROPHONE'));expected=$false},
                @{name='foreign service';devices=@(Make-Device -Service 'OtherDriver');expected=$false},
                @{name='service wildcard';devices=@(Make-Device -Service 'SesMicrophone*');expected=$false},
                @{name='non-root instance';devices=@(Make-Device 'USB\MEDIA\0000');expected=$false},
                @{name='foreign root class';devices=@(Make-Device 'ROOT\OTHER\0000');expected=$false},
                @{name='instance wildcard';devices=@(Make-Device 'ROOT\MEDIA\*');expected=$false},
                @{name='instance question mark';devices=@(Make-Device 'ROOT\MEDIA\000?');expected=$false},
                @{name='instance leading selector';devices=@(Make-Device '@ROOT\MEDIA\0000');expected=$false},
                @{name='instance trailing newline';devices=@(Make-Device "ROOT\MEDIA\0000`n");expected=$false},
                @{name='instance embedded carriage return';devices=@(Make-Device "ROOT\MEDIA\00`r00");expected=$false},
                @{name='instance NUL';devices=@(Make-Device ('ROOT\MEDIA\0000'+[char]0));expected=$false},
                @{name='instance shell delimiter';devices=@(Make-Device 'ROOT\MEDIA\0000&');expected=$false},
                @{name='instance short number';devices=@(Make-Device 'ROOT\MEDIA\000');expected=$false},
                @{name='instance long number';devices=@(Make-Device 'ROOT\MEDIA\00000');expected=$false},
                @{name='missing identity properties';devices=@([pscustomobject]@{DeviceID='ROOT\MEDIA\0000'});expected=$false},
                @{name='missing device';devices=@();expected=$false},
                @{name='duplicate matching devices';devices=@($real,(Make-Device 'ROOT\MEDIA\0001'));expected=$false}
            )){
                $script:identityDevices=$case.devices
                $accepted=$true;$selected=$null
                try{$selected=Assert-OneSesDevice}catch{$accepted=$false}
                [pscustomobject]@{passed=((Test-SesDeviceIdentity $case.devices) -eq $case.expected -and
                    $accepted -eq $case.expected -and (!$accepted -or [object]::ReferenceEquals($selected,$case.devices[0])));
                    name=('pure exact guest device identity '+$case.name)}
            }
        }).AddArgument($deviceIdentitySource)
        $identityResults=@($identityRunspace.Invoke())
        # Rejected identities intentionally throw in the assertion wrapper.
        if($identityRunspace.Streams.Error.Count -gt 0){throw ('Device identity fixtures failed: '+($identityRunspace.Streams.Error | Out-String))}
        Check ($identityResults.Count -eq 23) 'pure guest device identity fixture inventory complete'
        foreach($identityResult in $identityResults){Check $identityResult.passed $identityResult.name}
    }finally{$identityRunspace.Dispose()}
    $aclGuard=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-TrustedGuestAcl'},$true)
    $aclRunspace=[PowerShell]::Create()
    try{
        $null=$aclRunspace.AddScript({param($guard)
            . ([ScriptBlock]::Create($guard))
            function Get-Acl {param($LiteralPath) return $script:guardAcl}
            function Get-Item {param($LiteralPath) return [pscustomobject]@{PSIsContainer=$true}}
            function Make-TestAcl([string]$Owner,[bool]$Protected,[string]$Extra){
                $acl=[Security.AccessControl.DirectorySecurity]::new()
                $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($Owner));$acl.SetAccessRuleProtection($Protected,$false)
                foreach($sid in @('S-1-5-32-544','S-1-5-18')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
                if($Extra){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($Extra),'Write','Allow'))}
                return $acl
            }
            $results=@()
            foreach($case in @(
                @{owner='S-1-5-32-544';protect=$true;extra='';expected=$true},
                @{owner='S-1-5-18';protect=$true;extra='';expected=$true},
                @{owner='S-1-5-32-545';protect=$true;extra='';expected=$false},
                @{owner='S-1-5-32-544';protect=$true;extra='S-1-1-0';expected=$false},
                @{owner='S-1-5-32-544';protect=$false;extra='';expected=$false}
            )){
                $script:guardAcl=Make-TestAcl $case.owner $case.protect $case.extra
                $accepted=$true;try{Assert-TrustedGuestAcl 'inert-mocked-path'}catch{$accepted=$false}
                $results+=($accepted -eq $case.expected)
            }
            return $results
        }).AddArgument($aclGuard.Extent.Text)
        $aclResults=@($aclRunspace.Invoke())
        Check ($aclResults.Count -eq 5 -and @($aclResults | Where-Object { !$_ }).Count -eq 0) 'guest ACL guard accepts protected admins/SYSTEM and rejects foreign owners, public writers and inherited roots'
    }finally{$aclRunspace.Dispose()}
    # Only these pure function ASTs enter the fixture runspace. The guest
    # top-level script and its registry/verifier callers are never executed.
    # Execute only diagnostics helpers/branch extracted from actual guest source.
    # CIM, event logs, registry and process leaves are inert; no host query occurs.
    $diagnosticHelpers=@('Get-DeviceGuardArrayEvidence','Get-DeviceGuardEvidence','Get-BoundedEvents','Get-HvciDiagnosticEvents')
    $diagnosticSource=($diagnosticHelpers | ForEach-Object {
        $wanted=$_;$definition=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wanted},$true)
        if(!$definition){throw ('Missing diagnostics helper '+$wanted)};$definition.Extent.Text
    }) -join "`r`n"
    $diagnosticSwitch=$guestAst.Find({param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -ceq '$Mode'},$true)
    $diagnosticClause=@($diagnosticSwitch.Clauses | Where-Object {$_.Item1.Value -ceq 'Diagnostics'})[0].Item2.Extent.Text
    $diagnosticRunspace=[PowerShell]::Create()
    try{
        $null=$diagnosticRunspace.AddScript({param($helpers,$clause)
            $ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
            . ([ScriptBlock]::Create($helpers))
            function Emit-Fixture([bool]$Value,[string]$Name){[pscustomobject]@{passed=$Value;name=$Name}}
            function GuardRow{return [pscustomobject]@{VirtualizationBasedSecurityStatus=[uint32]2;SecurityServicesConfigured=@([uint32]2);SecurityServicesRunning=@([uint32]2);AvailableSecurityProperties=@([uint32]1,[uint32]2,[uint32]7);RequiredSecurityProperties=@([uint32]1)}}
            function Get-CimInstance {param($Namespace,$ClassName,$OperationTimeoutSec,$ErrorAction)
                if($ClassName -ceq 'Win32_Processor'){return [pscustomobject]@{Name='inert';VirtualizationFirmwareEnabled=$false;VMMonitorModeExtensions=$false;SecondLevelAddressTranslationExtensions=$false}}
                if($ClassName -cne 'Win32_DeviceGuard'){throw 'Host CIM access forbidden in diagnostics fixtures.'}
                $script:cimCall=@{namespace=$Namespace;class=$ClassName;timeout=$OperationTimeoutSec;errorAction=$ErrorAction}
                if($script:cimError){throw $script:cimError};return $script:rows
            }
            $script:cimError='';$script:rows=@(GuardRow);$e=Get-DeviceGuardEvidence
            Emit-Fixture ($script:cimCall.namespace -ceq 'root/Microsoft/Windows/DeviceGuard' -and $script:cimCall.class -ceq 'Win32_DeviceGuard' -and $script:cimCall.timeout -eq 5 -and $script:cimCall.errorAction -ceq 'Stop') 'DeviceGuard query uses fixed namespace/class and five-second terminating-error bound'
            Emit-Fixture ($e.AvailableSecurityPropertiesQuery -ceq 'Passed' -and $e.RequiredSecurityPropertiesQuery -ceq 'Passed' -and $e.AvailableSecurityProperties.Count -eq 3 -and $e.AvailableSecurityProperties[0] -is [int]) 'DeviceGuard capability arrays retain bounded typed numeric evidence'
            Emit-Fixture ($e.hvci -ceq 'Passed') 'HVCI evidence requires actual VBS running plus running service two'
            $script:rows[0].SecurityServicesRunning=@();Emit-Fixture ((Get-DeviceGuardEvidence).hvci -ceq 'Not run') 'configured-only HVCI cannot pass'
            $script:rows[0].SecurityServicesRunning=@(2);$script:rows[0].VirtualizationBasedSecurityStatus=1;Emit-Fixture ((Get-DeviceGuardEvidence).hvci -ceq 'Not run') 'running service alone cannot override inactive VBS'
            $script:rows[0].SecurityServicesRunning=@();Emit-Fixture ((Get-DeviceGuardEvidence).hvci -ceq 'Not run') 'available and required capabilities cannot imply active HVCI'
            $script:rows=@(GuardRow);$script:rows[0].PSObject.Properties.Remove('AvailableSecurityProperties');$script:rows[0].PSObject.Properties.Remove('RequiredSecurityProperties');$e=Get-DeviceGuardEvidence
            Emit-Fixture ($e.AvailableSecurityPropertiesQuery -ceq 'NotAvailable' -and $null -eq $e.AvailableSecurityProperties -and $e.RequiredSecurityPropertiesQuery -ceq 'NotAvailable' -and $null -eq $e.RequiredSecurityProperties) 'missing capability fields remain explicitly NotAvailable rather than invented empty arrays'
            $script:rows=@(GuardRow);$script:rows[0].AvailableSecurityProperties=@();$e=Get-DeviceGuardEvidence
            Emit-Fixture ($e.AvailableSecurityPropertiesQuery -ceq 'Passed' -and $e.AvailableSecurityProperties.Count -eq 0) 'reported empty capability array differs from unavailable evidence'
            foreach($value in @(@{v=@(1)*33},@{v=@('2')},@{v=@(-1)},@{v=@([decimal]2)},@{v=@($true)},@{v='2'},@{v=@([long]2147483648)})){
                $script:rows=@(GuardRow);$script:rows[0].AvailableSecurityProperties=$value.v;$e=Get-DeviceGuardEvidence
                Emit-Fixture ($e.AvailableSecurityPropertiesQuery -ceq 'Findings' -and $null -eq $e.AvailableSecurityProperties) 'malformed or oversized DeviceGuard capability array remains a finding'
            }
            $script:rows=@(GuardRow);$script:rows[0].PSObject.Properties.Remove('SecurityServicesRunning');$e=Get-DeviceGuardEvidence
            Emit-Fixture ($e.query -ceq 'Findings' -and $e.hvci -ceq 'Not run') 'missing running evidence cannot pass HVCI'
            $script:rows=@(GuardRow);$script:rows[0].VirtualizationBasedSecurityStatus='2';$e=Get-DeviceGuardEvidence
            Emit-Fixture ($e.query -ceq 'Findings' -and $e.hvci -ceq 'Not run') 'stringified VBS status cannot pass HVCI'
            $script:cimError='x'*700;$e=Get-DeviceGuardEvidence
            Emit-Fixture ($e.query -ceq 'Findings' -and $e.hvci -ceq 'Not run' -and $e.error.Length -eq 512 -and $null -eq $e.AvailableSecurityProperties) 'CIM failure remains visible bounded evidence without fabricated capabilities'
            $script:cimError='';$script:rows=@();Emit-Fixture ((Get-DeviceGuardEvidence).query -ceq 'Findings') 'empty DeviceGuard query is not success'
            $script:rows=@((GuardRow),(GuardRow));Emit-Fixture ((Get-DeviceGuardEvidence).query -ceq 'Findings') 'ambiguous DeviceGuard query is not success'
            function Get-WinEvent {
                [CmdletBinding()]param($FilterHashtable,$MaxEvents)
                $script:eventCalls+=@{filter=$FilterHashtable;maximum=$MaxEvents}
                if($script:eventMode -ceq 'error' -and $FilterHashtable.LogName -ceq 'Microsoft-Windows-DeviceGuard/Operational'){throw ('optional log unavailable '+('x'*700))}
                if($script:eventMode -cne 'events'){$PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new([Exception]::new('No matching events'),'NoMatchingEventsFound',[Management.Automation.ErrorCategory]::ObjectNotFound,$null))}
                foreach($id in 1..40){[pscustomobject]@{Id=$id;TimeCreated=[DateTime]::UtcNow;ProviderName='inert provider';Message=('m'*700)}}
            }
            $script:eventCalls=@();$script:eventMode='events';$events=Get-HvciDiagnosticEvents
            Emit-Fixture ($script:eventCalls.Count -eq 2 -and $script:eventCalls[0].maximum -eq 32 -and $script:eventCalls[0].filter.LogName -ceq 'System' -and $script:eventCalls[0].filter.ProviderName -ceq 'Microsoft-Windows-Hyper-V-Hypervisor' -and ($script:eventCalls[0].filter.Level -join ',') -ceq '1,2,3' -and $script:eventCalls[1].filter.LogName -ceq 'Microsoft-Windows-DeviceGuard/Operational') 'boot diagnostics use exact Hyper-V provider and DeviceGuard log with bounded warning/error filters'
            Emit-Fixture ($events.hypervisor.events.Count -eq 32 -and $events.deviceGuard.events.Count -eq 32 -and @($events.hypervisor.events | Where-Object {$_.message.Length -ne 512}).Count -eq 0) 'diagnostic events and messages retain hard 32-event and 512-character bounds'
            Emit-Fixture ($events.hypervisor.events[0].id -eq 1 -and $events.hypervisor.events[31].id -eq 32 -and $events.hypervisor.events[0].utc -is [string]) 'bounded boot warnings retain event IDs provider and UTC evidence'
            $script:eventCalls=@();$null=Get-BoundedEvents 'System' ([Nullable[int]]1001)
            Emit-Fixture ($script:eventCalls[0].filter.Id -eq 1001 -and !$script:eventCalls[0].filter.ContainsKey('Level') -and !$script:eventCalls[0].filter.ContainsKey('ProviderName')) 'legacy event ID query keeps its unchanged two-argument filter'
            $null=Get-BoundedEvents 'Microsoft-Windows-CodeIntegrity/Operational' $null
            Emit-Fixture (($script:eventCalls[1].filter.Level -join ',') -ceq '1,2' -and !$script:eventCalls[1].filter.ContainsKey('ProviderName')) 'legacy event error query keeps default critical/error levels without provider restriction'
            $script:eventMode='quiet';$events=Get-HvciDiagnosticEvents
            Emit-Fixture ($events.hypervisor.query -ceq 'Passed' -and $events.hypervisor.events.Count -eq 0 -and $events.deviceGuard.query -ceq 'Passed' -and $events.deviceGuard.events.Count -eq 0) 'no matching optional boot events are an empty successful query'
            $script:eventMode='error';$events=Get-HvciDiagnosticEvents
            Emit-Fixture ($events.hypervisor.query -ceq 'Passed' -and $events.deviceGuard.query -ceq 'Findings' -and $null -eq $events.deviceGuard.events -and $events.deviceGuard.error.Length -eq 512) 'optional event query failure is retained as bounded Findings without aborting diagnostics'
            function New-Result {param($Status)return @{status=$Status}}
            function Get-WindowsLicenseEvidence {return @{LicenseStatus=1}}
            function Invoke-BoundedTool {return @{exitCode=0;timedOut=$false;outputLimited=$false}}
            function Get-SavedVerifierEvidence {return @{configured=$false}}
            function Get-ActiveVerifierEvidence {return @{activeVerified=$false}}
            function Write-Report {param($Name,$Value)$script:diagnosticsReport=$Value}
            function Get-Acl {throw 'Host registry/ACL access forbidden in diagnostics fixtures.'}
            $system32='C:\Windows\System32';$body=$clause.Substring(1,$clause.Length-2)
            $script:rows=@(GuardRow);$script:rows[0].SecurityServicesRunning=@();$script:eventMode='quiet';& ([ScriptBlock]::Create($body))
            Emit-Fixture ($script:diagnosticsReport.status -ceq 'Passed' -and $script:diagnosticsReport.deviceGuard.hvci -ceq 'Not run') 'actual diagnostics branch never mistakes configured-only capability evidence for HVCI Passed'
            $script:eventMode='error';& ([ScriptBlock]::Create($body))
            Emit-Fixture ($script:diagnosticsReport.status -ceq 'Findings' -and $script:diagnosticsReport.hvciBootDiagnostics.deviceGuard.query -ceq 'Findings') 'actual diagnostics branch exposes optional log query failure as Findings'
            $script:eventMode='events';& ([ScriptBlock]::Create($body))
            Emit-Fixture ($script:diagnosticsReport.status -ceq 'Findings') 'actual diagnostics branch reports retained boot warnings as Findings'
            $script:eventMode='quiet';$script:rows[0].AvailableSecurityProperties=@('2');& ([ScriptBlock]::Create($body))
            Emit-Fixture ($script:diagnosticsReport.status -ceq 'Findings') 'actual diagnostics branch reports malformed capability evidence as Findings'
            $script:rows[0].PSObject.Properties.Remove('AvailableSecurityProperties');$script:rows[0].PSObject.Properties.Remove('RequiredSecurityProperties');& ([ScriptBlock]::Create($body))
            Emit-Fixture ($script:diagnosticsReport.status -ceq 'Passed' -and $script:diagnosticsReport.deviceGuard.AvailableSecurityPropertiesQuery -ceq 'NotAvailable' -and $script:diagnosticsReport.deviceGuard.hvci -ceq 'Not run') 'older guard class stays diagnostically usable with explicit unavailable capabilities and no HVCI claim'
        }).AddArgument($diagnosticSource).AddArgument($diagnosticClause)
        $diagnosticResults=@($diagnosticRunspace.Invoke())
        if($diagnosticRunspace.HadErrors){throw ('Inert diagnostics fixture failure: '+($diagnosticRunspace.Streams.Error | Out-String))}
        Check ($diagnosticResults.Count -eq 32) 'read-only DeviceGuard and boot diagnostics fixture inventory complete'
        foreach($diagnosticResult in $diagnosticResults){Check $diagnosticResult.passed $diagnosticResult.name}
    }finally{$diagnosticRunspace.Dispose()}
    $verifierHelpers=@('ConvertFrom-VerifierRegistryEvidence','Get-VerifierEnableDecision','ConvertFrom-VerifierActiveEvidence','Get-HvciLabDecision','Test-HvciBaselineFresh','Test-HvciBeforeBcdEvidence')
    $verifierSource=($verifierHelpers | ForEach-Object {
        $wanted=$_
        $definition=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wanted},$true)
        if(!$definition){throw ('Missing pure verifier helper '+$wanted)}
        $definition.Extent.Text
    }) -join "`r`n"
    $verifierRunspace=[PowerShell]::Create()
    try{
        $null=$verifierRunspace.AddScript({param($helpers)
            $ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
            . ([ScriptBlock]::Create($helpers))
            function Get-Acl {throw 'Pure verifier fixtures must not access host registry ACLs.'}
            function Get-CimInstance {throw 'Pure verifier fixtures must not access host CIM.'}
            function verifier.exe {throw 'Pure verifier fixtures must never launch host verifier.'}
            function bcdedit.exe {throw 'Pure HVCI fixtures must never launch host BCDEdit.'}
            function New-ItemProperty {throw 'Pure HVCI fixtures must not change host registry.'}
            function Emit-Fixture([bool]$Passed,[string]$Name){[pscustomobject]@{passed=$Passed;name=$Name}}
            $saved=ConvertFrom-VerifierRegistryEvidence 0x021209bb 'SesMicrophone.sys' 'DWord' 'String' $true
            Emit-Fixture ($saved.configured -and !$saved.hvciEvidence) 'exact DWORD and sole driver settings accepted without claiming HVCI'
            foreach($case in @(
                @{name='missing Code Integrity bit';level=0x001209bb;drivers='SesMicrophone.sys';levelKind='DWord';driverKind='String';protected=$true},
                @{name='extra flags';level=0x021209bf;drivers='SesMicrophone.sys';levelKind='DWord';driverKind='String';protected=$true},
                @{name='another driver';level=0x021209bb;drivers='SesMicrophone.sys other.sys';levelKind='DWord';driverKind='String';protected=$true},
                @{name='duplicate driver';level=0x021209bb;drivers='SesMicrophone.sys SesMicrophone.sys';levelKind='DWord';driverKind='String';protected=$true},
                @{name='empty drivers';level=0x021209bb;drivers='';levelKind='DWord';driverKind='String';protected=$true},
                @{name='path masquerading as driver';level=0x021209bb;drivers='C:\Windows\SesMicrophone.sys';levelKind='DWord';driverKind='String';protected=$true},
                @{name='string mask';level='0x021209bb';drivers='SesMicrophone.sys';levelKind='DWord';driverKind='String';protected=$true},
                @{name='wrong registry mask kind';level=0x021209bb;drivers='SesMicrophone.sys';levelKind='String';driverKind='String';protected=$true},
                @{name='wrong registry drivers kind';level=0x021209bb;drivers='SesMicrophone.sys';levelKind='DWord';driverKind='MultiString';protected=$true},
                @{name='unverified registry protection';level=0x021209bb;drivers='SesMicrophone.sys';levelKind='DWord';driverKind='String';protected=$false}
            )){
                $e=ConvertFrom-VerifierRegistryEvidence $case.level $case.drivers $case.levelKind $case.driverKind $case.protected
                Emit-Fixture (!$e.configured) ('saved verifier rejects '+$case.name)
            }
            foreach($code in @(0,2)){
                $decision=Get-VerifierEnableDecision $code $false $false $saved
                Emit-Fixture ($decision.rebootRequired -and $decision.status -ceq 'Reboot required' -and !$decision.activeVerified -and !$decision.hvciEvidence) ('enable exit '+$code+' requires verified settings and reports reboot only')
            }
            foreach($code in @(1,3,-1)){
                Emit-Fixture (!(Get-VerifierEnableDecision $code $false $false $saved).rebootRequired) ('unknown enable exit '+$code+' rejected')
            }
            Emit-Fixture (!(Get-VerifierEnableDecision 2 $true $false $saved).rebootRequired) 'enable timeout rejected despite matching settings'
            Emit-Fixture (!(Get-VerifierEnableDecision 2 $false $true $saved).rebootRequired) 'enable output flood rejected despite matching settings'
            Emit-Fixture (!(Get-VerifierEnableDecision 2 $false $false @{configured=$false}).rebootRequired) 'exit 2 alone never proves configured verifier'
            Emit-Fixture (!(Get-VerifierEnableDecision '2' $false $false $saved).rebootRequired) 'unknown enable exit type rejected'
            Emit-Fixture (!(Get-VerifierEnableDecision 2 $false $false $null).rebootRequired) 'missing configured evidence rejected'
            $active="Time Stamp: fixture`r`nVerifier Flags: 0x021209bb`r`nDriver Verification List`r`nMODULE: SesMicrophone.sys (load: 1 / unload: 0)`r`nPool Allocation Statistics: fixture"
            $e=ConvertFrom-VerifierActiveEvidence $active 0 $false $false
            Emit-Fixture ($e.activeVerified -and $e.flags -ceq '0x021209bb' -and !$e.hvciEvidence) 'postboot query separately proves exact flags and sole loaded target'
            foreach($case in @(
                @{name='missing CI bit';text=$active.Replace('0x021209bb','0x001209bb');code=0;timeout=$false;flood=$false},
                @{name='second driver';text=($active+"`r`nMODULE: other.sys (load: 1 / unload: 0)");code=0;timeout=$false;flood=$false},
                @{name='malformed second module';text=($active+"`r`nMODULE: other.sys malformed");code=0;timeout=$false;flood=$false},
                @{name='only saved settings';text="Verifier Flags: 0x021209bb`r`nVerified Drivers:`r`nSesMicrophone.sys";code=0;timeout=$false;flood=$false},
                @{name='unloaded target';text=$active.Replace('load: 1 / unload: 0','load: 1 / unload: 1');code=0;timeout=$false;flood=$false},
                @{name='overflowing load count';text=$active.Replace('load: 1 / unload: 0','load: 999999999999999999999 / unload: 0');code=0;timeout=$false;flood=$false},
                @{name='duplicate flags';text=($active+"`r`nVerifier Flags: 0x021209bb");code=0;timeout=$false;flood=$false},
                @{name='query exit 2';text=$active;code=2;timeout=$false;flood=$false},
                @{name='query timeout';text=$active;code=0;timeout=$true;flood=$false},
                @{name='query output flood';text=$active;code=0;timeout=$false;flood=$true},
                @{name='oversized query';text=($active+('x'*65537));code=0;timeout=$false;flood=$false},
                @{name='unknown query format';text='unrecognized localized verifier output';code=0;timeout=$false;flood=$false}
            )){
                $e=ConvertFrom-VerifierActiveEvidence $case.text $case.code $case.timeout $case.flood
                Emit-Fixture (!$e.activeVerified) ('active verifier rejects '+$case.name)
            }
            $hvciSettings=@{EnableVirtualizationBasedSecurity=@{kind='DWord';value=1};RequirePlatformSecurityFeatures=@{kind='DWord';value=0};
                DeviceGuardLocked=@{kind='DWord';value=0};HvciEnabled=@{kind='DWord';value=1};HvciLocked=@{kind='DWord';value=0}}
            $e=Get-HvciLabDecision $hvciSettings 0 $false $false 0 $false $false
            Emit-Fixture ($e.settingsPersisted -and $e.rebootRequired -and !$e.activeVerified -and $e.hvci -ceq 'Not run' -and !$e.uefiLockRequested) 'HVCI persistence and successful BCD report reboot without active HVCI claim'
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 1 $false $false 0 $false $false).settingsPersisted) 'HVCI failed BCD command rejected'
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $true $false 0 $false $false).settingsPersisted) 'HVCI timed out BCD command rejected'
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $true 0 $false $false).settingsPersisted) 'HVCI flooded BCD command rejected'
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $false 1 $false $false).settingsPersisted) 'HVCI failed VSM command rejected'
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $false 0 $true $false).settingsPersisted) 'HVCI timed out VSM command rejected'
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $false 0 $false $true).settingsPersisted) 'HVCI flooded VSM command rejected'
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $false).settingsPersisted) 'HVCI missing VSM command evidence rejected'
            Emit-Fixture (Test-HvciBaselineFresh $false $false) 'HVCI fresh baseline may proceed to bounded read-only export'
            Emit-Fixture (!(Test-HvciBaselineFresh $true $false)) 'HVCI retry preserves original snapshot'
            Emit-Fixture (!(Test-HvciBaselineFresh $false $true)) 'HVCI retry preserves original BCD log even after a failed snapshot'
            Emit-Fixture (!(Test-HvciBaselineFresh $true $true)) 'HVCI retry preserves both original baseline files'
            Emit-Fixture (!(Test-HvciBaselineFresh 'false' $false)) 'HVCI unknown baseline existence type rejected'
            $bcdBefore="Windows Boot Loader`r`nidentifier              {current}`r`nhypervisorlaunchtype    Off`r`nvsmlaunchtype           Off"
            Emit-Fixture (Test-HvciBeforeBcdEvidence $bcdBefore 0 $false $false) 'HVCI original current-loader BCD export accepted before mutations'
            Emit-Fixture (!(Test-HvciBeforeBcdEvidence $bcdBefore 1 $false $false)) 'HVCI original BCD query failure rejects configuration'
            Emit-Fixture (!(Test-HvciBeforeBcdEvidence $bcdBefore 0 $true $false)) 'HVCI original BCD query timeout rejects configuration'
            Emit-Fixture (!(Test-HvciBeforeBcdEvidence $bcdBefore 0 $false $true)) 'HVCI original BCD query flood rejects configuration'
            Emit-Fixture (!(Test-HvciBeforeBcdEvidence '' 0 $false $false)) 'HVCI empty original BCD query rejects configuration'
            Emit-Fixture (!(Test-HvciBeforeBcdEvidence ($bcdBefore+('x'*65537)) 0 $false $false)) 'HVCI oversized original BCD query rejects configuration'
            Emit-Fixture (!(Test-HvciBeforeBcdEvidence 'unknown loader output' 0 $false $false)) 'HVCI unknown original BCD query format rejects configuration'
            Emit-Fixture (!(Test-HvciBeforeBcdEvidence ($bcdBefore+"`r`nidentifier {current}") 0 $false $false)) 'HVCI ambiguous original BCD query rejects configuration'
            $hvciSettings.HvciEnabled.value=0
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $false 0 $false $false).settingsPersisted) 'HVCI disabled saved value rejected'
            $hvciSettings.HvciEnabled.value=1;$hvciSettings.DeviceGuardLocked.value=1
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $false 0 $false $false).settingsPersisted) 'HVCI locked configuration rejected'
            $hvciSettings.DeviceGuardLocked.value=0;$hvciSettings.HvciEnabled.kind='String'
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $false 0 $false $false).settingsPersisted) 'HVCI wrong registry value kind rejected'
            $hvciSettings.Remove('HvciEnabled')
            Emit-Fixture (!(Get-HvciLabDecision $hvciSettings 0 $false $false 0 $false $false).settingsPersisted) 'HVCI missing saved value rejected'
            Emit-Fixture (!(Get-HvciLabDecision $null 0 $false $false 0 $false $false).settingsPersisted) 'HVCI missing settings evidence rejected'
        }).AddArgument($verifierSource)
        $verifierResults=@($verifierRunspace.Invoke())
        if($verifierRunspace.HadErrors){throw ('Pure verifier fixture failure: '+($verifierRunspace.Streams.Error | Out-String))}
        Check ($verifierResults.Count -eq 60) 'pure verifier and HVCI regression fixture inventory complete'
        foreach($verifierResult in $verifierResults){Check $verifierResult.passed $verifierResult.name}
    }finally{$verifierRunspace.Dispose()}
    # Run only the extracted HVCI clause with inert command mocks: a retry must
    # stop before even the first device/registry read or process invocation.
    $modeSwitch=$guestAst.Find({param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -ceq '$Mode'},$true)
    $hvciClause=@($modeSwitch.Clauses | Where-Object {$_.Item1.Value -ceq 'EnableHvciLab'})[0].Item2.Extent.Text
    $hvciBody=$hvciClause.Substring(1,$hvciClause.Length-2)
    $snapshotWriter=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Write-FirstHvciSnapshot'},$true)
    $baselineGuard=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-HvciBaselineFresh'},$true)
    $baselineRunspace=[PowerShell]::Create()
    try{
        $null=$baselineRunspace.AddScript({param($guard,$body,$writer,$fixtureDirectory)
            $ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
            . ([ScriptBlock]::Create($guard))
            function Get-OutputPath {param($Name) return $Name}
            function Test-Path {param($LiteralPath) if($LiteralPath -ceq 'hvci-snapshot.json'){return $script:existsSnapshot};return $script:existsBeforeLog}
            function New-Result {throw 'Fresh baseline reached the first read stage.'}
            function Invoke-BoundedTool {throw 'Retry must not execute any tool.'}
            function Get-DeviceGuardEvidence {throw 'Retry must not read guest state.'}
            function Read-HvciLabSettings {throw 'Retry must not read registry state.'}
            function New-ItemProperty {throw 'Retry must not mutate registry state.'}
            foreach($case in @(@{snapshot=$true;log=$false},@{snapshot=$false;log=$true},@{snapshot=$true;log=$true},@{snapshot=$false;log=$false})){
                $script:existsSnapshot=$case.snapshot;$script:existsBeforeLog=$case.log
                $message='';try{& ([ScriptBlock]::Create($body))}catch{$message=$_.Exception.Message}
                $expected=if($case.snapshot -or $case.log){'Preserving the first HVCI baseline:*'}else{'Fresh baseline reached the first read stage.'}
                [pscustomobject]@{passed=($message -like $expected);name=('HVCI inert mode guard snapshot='+$case.snapshot+' originalLog='+$case.log)}
            }
            # Files here are inert JSON in the owned regression fixture. Only
            # the snapshot writer AST executes, with ACL/COM1 mocked entirely.
            . ([ScriptBlock]::Create($writer))
            function Get-OutputPath {param($Name) return (Join-Path $fixtureDirectory $Name)}
            function Assert-TrustedGuestAcl {param($Path)}
            function Write-Serial {param($Tag,$Value)}
            $first=@{settingsBefore=@{Enabled=0};bcdBeforeText='first original BCD';schema=1}
            Write-FirstHvciSnapshot $first
            $file=Join-Path $fixtureDirectory 'hvci-snapshot.json';$originalBytes=[IO.File]::ReadAllBytes($file)
            $rejected=$false;try{Write-FirstHvciSnapshot @{settingsBefore=@{Enabled=1};bcdBeforeText='replacement'}}catch{$rejected=$true}
            $afterBytes=[IO.File]::ReadAllBytes($file)
            [pscustomobject]@{passed=($rejected -and [Convert]::ToBase64String($originalBytes) -ceq [Convert]::ToBase64String($afterBytes));name='HVCI atomic CreateNew snapshot rejects retry and preserves first bytes'}
        }).AddArgument($baselineGuard.Extent.Text).AddArgument($hvciBody).AddArgument($snapshotWriter.Extent.Text).AddArgument($fixture)
        $baselineResults=@($baselineRunspace.Invoke())
        # HadErrors also records intentionally caught guard/CreateNew failures.
        if($baselineRunspace.Streams.Error.Count -gt 0){throw ('Inert HVCI baseline fixtures failed: '+($baselineRunspace.Streams.Error | Out-String))}
        Check ($baselineResults.Count -eq 5) 'inert HVCI baseline integration fixture inventory complete'
        foreach($baselineResult in $baselineResults){Check $baselineResult.passed $baselineResult.name}
    }finally{$baselineRunspace.Dispose()}
    # WinPS 5.1 registry Get-Acl must use -Path. AST checks cover both callers;
    # the registry guard itself runs against mocked ACLs, never the host hive.
    foreach($registryCaller in @('Get-SavedVerifierEvidence','Assert-ProtectedRegistryPath')){
        $registryDefinition=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $registryCaller},$true)
        $registryAclCall=$registryDefinition.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Acl'},$true)
        $aclParameters=@($registryAclCall.CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst]} | ForEach-Object {$_.ParameterName})
        Check ($aclParameters -contains 'Path' -and $aclParameters -notcontains 'LiteralPath') ('WinPS registry ACL caller uses fixed provider Path: '+$registryCaller)
    }
    $filesystemAclCall=$aclGuard.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Acl'},$true)
    $filesystemAclParameters=@($filesystemAclCall.CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst]} | ForEach-Object {$_.ParameterName})
    Check ($filesystemAclParameters -contains 'LiteralPath' -and $filesystemAclParameters -notcontains 'Path') 'filesystem guest ACL guard preserves LiteralPath'
    $registryGuard=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-ProtectedRegistryPath'},$true)
    $registryRunspace=[PowerShell]::Create()
    try{
        $null=$registryRunspace.AddScript({param($guard)
            $ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
            . ([ScriptBlock]::Create($guard))
            $script:registryAclCalls=0
            function Get-Acl {param($Path,$LiteralPath)
                if(!$PSBoundParameters.ContainsKey('Path') -or $PSBoundParameters.ContainsKey('LiteralPath')){throw 'Mock WinPS registry ACL requires Path.'}
                $script:registryAclCalls++;return $script:registryAcl
            }
            function Make-RegistryFixture([string]$Owner,[string]$PublicAccess){
                $acl=[Security.AccessControl.RegistrySecurity]::new()
                $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($Owner))
                foreach($sid in @('S-1-5-18','S-1-5-32-544')){
                    $acl.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.RegistryRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
                }
                if($PublicAccess){$acl.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.RegistryRights]::$PublicAccess,[Security.AccessControl.AccessControlType]::Allow))}
                return $acl
            }
            $script:registryAcl=Make-RegistryFixture 'S-1-5-18' ''
            $prefix='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control'
            foreach($path in @($prefix,($prefix+'\DeviceGuard'),($prefix+'\DeviceGuard\Scenarios'),($prefix+'\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'))){
                $calls=$script:registryAclCalls;$accepted=$true;try{Assert-ProtectedRegistryPath $path}catch{$accepted=$false}
                [pscustomobject]@{passed=($accepted -and $script:registryAclCalls -eq $calls+1);name=('mocked registry provider Path accepts exact protected key '+$path)}
            }
            foreach($path in @(($prefix+'\DeviceGuard*'),'Registry::HKEY_LOCAL_MACHINE\SOFTWARE')){
                $calls=$script:registryAclCalls;$accepted=$true;try{Assert-ProtectedRegistryPath $path}catch{$accepted=$false}
                [pscustomobject]@{passed=(!$accepted -and $script:registryAclCalls -eq $calls);name=('registry whitelist rejects caller path before any ACL read '+$path)}
            }
            foreach($case in @(@{owner='S-1-5-32-545';access='';expected=$false},@{owner='S-1-5-18';access='SetValue';expected=$false},@{owner='S-1-5-18';access='ReadKey';expected=$true})){
                $script:registryAcl=Make-RegistryFixture $case.owner $case.access
                $accepted=$true;try{Assert-ProtectedRegistryPath ($prefix+'\DeviceGuard')}catch{$accepted=$false}
                [pscustomobject]@{passed=($accepted -eq $case.expected);name=('registry ACL enforcement owner='+$case.owner+' publicAccess='+$case.access)}
            }
        }).AddArgument($registryGuard.Extent.Text)
        $registryResults=@($registryRunspace.Invoke())
        if($registryRunspace.Streams.Error.Count -gt 0){throw ('Mocked registry ACL fixtures failed: '+($registryRunspace.Streams.Error | Out-String))}
        Check ($registryResults.Count -eq 9) 'mocked WinPS registry ACL fixture inventory complete'
        foreach($registryResult in $registryResults){Check $registryResult.passed $registryResult.name}
    }finally{$registryRunspace.Dispose()}
    # Only isolated helper ASTs and the extracted prepare clause execute here.
    # Guest/host power tools, CIM, event log access and COM1 are inert mocks.
    $hibernateHelpers=@('ConvertFrom-HibernateEventXml','Get-HibernateResumeDecision','Get-HibernateEvents','Write-FirstHibernateSnapshot',
        'Get-HibernateSessionEvidence','Test-HibernateLogonSession','Test-HibernateInteractiveMembership')
    $hibernateSource=($hibernateHelpers | ForEach-Object {
        $wanted=$_
        $definition=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wanted},$true)
        if(!$definition){throw ('Missing hibernate helper '+$wanted)}
        $helperSource=$definition.Extent.Text
        if($wanted -ceq 'Get-HibernateSessionEvidence'){
            # Substitute only the extracted test copy's three platform calls.
            # CI may run in session 0; no real token/session controls this fixture.
            foreach($replacement in @(
                @{from='[Security.Principal.WindowsIdentity]::GetCurrent()';to='(New-FixtureHibernateIdentity)'},
                @{from='[Security.Principal.WindowsPrincipal]::new($identity)';to='(New-FixtureHibernatePrincipal $identity)'},
                @{from='[Diagnostics.Process]::GetCurrentProcess().SessionId';to='(Get-FixtureHibernateSessionId)'}
            )){
                if([regex]::Matches($helperSource,[regex]::Escape($replacement.from)).Count -ne 1){throw 'Hibernate fixture platform substitution changed.'}
                $helperSource=$helperSource.Replace($replacement.from,$replacement.to)
            }
        }
        $helperSource
    }) -join "`r`n"
    $hibernateClause=@($modeSwitch.Clauses | Where-Object {$_.Item1.Value -ceq 'HibernatePrepare'})[0].Item2.Extent.Text
    $hibernateBody=$hibernateClause.Substring(1,$hibernateClause.Length-2)
    $hibernateVerifyClause=@($modeSwitch.Clauses | Where-Object {$_.Item1.Value -ceq 'HibernateVerify'})[0].Item2.Extent.Text
    $hibernateVerifyBody=$hibernateVerifyClause.Substring(1,$hibernateVerifyClause.Length-2)
    $hibernateRunspace=[PowerShell]::Create()
    try{
        $null=$hibernateRunspace.AddScript({param($source,$body,$verifyBody,$fixtureDirectory)
            $ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
            . ([ScriptBlock]::Create($source))
            function Emit([bool]$Passed,[string]$Name){[pscustomobject]@{passed=$Passed;name=('hibernate '+$Name)}}
            $script:disposedIdentities=0
            function New-FixtureHibernateIdentity {
                $mock=[pscustomobject]@{User=[pscustomobject]@{Value='S-1-5-21-1-2-3-500'}}
                $mock | Add-Member -MemberType ScriptMethod -Name Dispose -Value {$script:disposedIdentities++}
                return $mock
            }
            function New-FixtureHibernatePrincipal {param($Identity)
                if($Identity.User.Value -cne 'S-1-5-21-1-2-3-500'){throw 'Unexpected inert identity.'}
                $mock=[pscustomobject]@{}
                $mock | Add-Member -MemberType ScriptMethod -Name IsInRole -Value {param($Sid) return $Sid.Value -ceq 'S-1-5-4'}
                return $mock
            }
            function Get-FixtureHibernateSessionId {return 1}
            $vmId='11111111-2222-3333-4444-555555555555'
            function New-Session {
                return @{bootUtc='2026-10-09T07:00:00.0000000Z';userSid='S-1-5-21-1-2-3-500';authenticationId='0000000000000100';interactive=$true;sessionId=1}
            }
            function New-Baseline {
                return @{schema=1;vmId=$vmId;mode='HibernatePrepare';status='Snapshot';testOnly=$true;
                    utc='2026-10-09T08:00:00.0000000Z';eventRecordId=[long]100;session=(New-Session)}
            }
            function New-EventXml([string]$Provider,[int]$Id,[long]$Record,[string]$Utc,[string]$Data){
                return '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="'+$Provider+'"/><EventID>'+$Id+'</EventID><TimeCreated SystemTime="'+$Utc+'"/><EventRecordID>'+$Record+'</EventRecordID></System><EventData>'+$Data+'</EventData></Event>'
            }
            function New-Events {
                $states='<Data Name="TargetState">5</Data><Data Name="EffectiveState">5</Data>'
                return @(
                    (ConvertFrom-HibernateEventXml (New-EventXml 'Microsoft-Windows-Kernel-Power' 42 101 '2026-10-09T08:00:05.0000000Z' $states)),
                    (ConvertFrom-HibernateEventXml (New-EventXml 'Microsoft-Windows-Power-Troubleshooter' 1 102 '2026-10-09T08:02:01.0000000Z' ($states+'<Data Name="SleepTime">2026-10-09T08:00:05.0000000Z</Data><Data Name="WakeTime">2026-10-09T08:02:00.0000000Z</Data>')))
                )
            }
            $now='2026-10-09T08:03:00.0000000Z'
            $baseline=New-Baseline;$session=New-Session;$events=New-Events
            $decision=Get-HibernateResumeDecision $baseline $session $events $vmId $now
            Emit ($decision.status -ceq 'Passed' -and $decision.resumeVerified -and $decision.sleepRecordId -eq 101 -and $decision.wakeRecordId -eq 102) 'paired S4 XML and original session accepted'
            Emit ((Get-HibernateResumeDecision $baseline $session @($events[1],$events[0]) $vmId $now).resumeVerified) 'reverse query order still uses record order'
            Emit (!(Get-HibernateResumeDecision $null $session $events $vmId $now).resumeVerified) 'missing snapshot rejected'
            Emit (!(Get-HibernateResumeDecision $baseline $session @() $vmId $now).resumeVerified) 'request success without events cannot pass'
            foreach($field in @('bootUtc','userSid','authenticationId','interactive','sessionId')){
                $changed=New-Session;$changed[$field]=if($field -ceq 'sessionId'){2}else{'changed'}
                Emit (!(Get-HibernateResumeDecision $baseline $changed $events $vmId $now).resumeVerified) ('continuity mismatch rejected '+$field)
            }
            foreach($value in @($null,100,'0000000000000000','000000000000010','00000000000000100','000000000000010G','00000000000000FF')){
                $changed=New-Session;$changed.authenticationId=$value
                $changedBaseline=New-Baseline;$changedBaseline.session.authenticationId=$value
                Emit (!(Get-HibernateResumeDecision $changedBaseline $changed $events $vmId $now).resumeVerified) 'missing zero non-string malformed or noncanonical authentication LUID rejected'
            }
            $changed=New-Baseline;$changed.session.Remove('authenticationId');$changed.session.logonSid='S-1-5-5-0-100'
            Emit (!(Get-HibernateResumeDecision $changed $session $events $vmId $now).resumeVerified) 'obsolete group-logon-SID baseline cannot pass'
            foreach($field in @('userSid','authenticationId','interactive','sessionId')){
                $values=switch($field){
                    'userSid' {@('S-1-5-18','S-1-5-19','S-1-5-20','S-1-5-7')}
                    'authenticationId' {@('00000000000003e4','00000000000003e5','00000000000003e6','00000000000003e7')}
                    'interactive' {@($null,$false,'true',1)}
                    'sessionId' {@(0,'1')}
                }
                foreach($value in $values){
                    $changed=New-Session;$changed[$field]=$value;$changedBaseline=New-Baseline;$changedBaseline.session[$field]=$value
                    Emit (!(Test-HibernateLogonSession $changed) -and !(Get-HibernateResumeDecision $changedBaseline $changed $events $vmId $now).resumeVerified) ('service anonymous noninteractive or malformed session rejected '+$field)
                }
            }
            $changed=New-Baseline;$changed.session.Remove('interactive')
            Emit (!(Get-HibernateResumeDecision $changed $session $events $vmId $now).resumeVerified) 'legacy baseline without interactive membership proof rejected'
            foreach($case in @(@{interactive=$true;remote=$false;expected=$true},@{interactive=$false;remote=$true;expected=$true},@{interactive=$false;remote=$false;expected=$false})){
                $mockPrincipal=[pscustomobject]@{interactive=$case.interactive;remote=$case.remote;calls=@()}
                $mockPrincipal | Add-Member -MemberType ScriptMethod -Name IsInRole -Value {
                    param($Sid);$this.calls+=,$Sid.Value
                    if($Sid.Value -ceq 'S-1-5-4'){return $this.interactive}
                    if($Sid.Value -ceq 'S-1-5-14'){return $this.remote};throw 'Unexpected role SID.'
                }
                $membership=Test-HibernateInteractiveMembership $mockPrincipal
                Emit ($membership -eq $case.expected -and $mockPrincipal.calls[0] -ceq 'S-1-5-4' -and
                    ($case.interactive -or $mockPrincipal.calls[1] -ceq 'S-1-5-14')) 'only enabled interactive or remote-interactive roles accepted'
            }
            # Only the current identity lifetime is read; native token querying
            # and OS boot data are mocked. No DLL, CIM or power command executes.
            $script:nativeReads=0;$script:bootReads=0;$script:mockAuthenticationId='0000000000000100'
            function Read-HibernateAuthenticationId {param($Identity)
                if(!$Identity){throw 'Missing identity in mocked token reader.'}
                $script:nativeReads++;if($script:mockAuthenticationId -ceq 'throw'){throw 'inert token query failure'}
                return $script:mockAuthenticationId
            }
            function Get-CimInstance {param($ClassName)
                if($ClassName -cne 'Win32_OperatingSystem'){throw 'Unexpected inert CIM class.'}
                $script:bootReads++;return [pscustomobject]@{LastBootUpTime=[DateTime]::SpecifyKind([DateTime]'2026-10-09T07:00:00',[DateTimeKind]::Utc)}
            }
            $actual=Get-HibernateSessionEvidence
            Emit ($actual.authenticationId -ceq '0000000000000100' -and $actual.bootUtc -ceq '2026-10-09T07:00:00.0000000Z' -and
                $actual.sessionId -ceq 1 -and $actual.interactive -ceq $true -and $script:nativeReads -eq 1 -and $script:bootReads -eq 1 -and
                $script:disposedIdentities -eq 1 -and !$actual.ContainsKey('logonSid')) 'session collector uses inert identity session and enabled interactive membership and disposes identity'
            foreach($value in @($null,100,'0000000000000000','000000000000010','00000000000000100','000000000000010G','00000000000000FF','throw')){
                $script:mockAuthenticationId=$value;$reads=$script:bootReads;$disposed=$script:disposedIdentities;$rejected=$false;$message=''
                try{Get-HibernateSessionEvidence | Out-Null}catch{$rejected=$true;$message=$_.Exception.Message}
                Emit ($rejected -and $script:bootReads -eq $reads -and $script:disposedIdentities -eq ($disposed+1) -and
                    ($value -cne 'throw' -or $message -ceq 'inert token query failure')) 'invalid or failed native LUID read stops before boot query and disposes identity'
            }
            foreach($value in @('00000000000003e4','00000000000003e5','00000000000003e6','00000000000003e7')){
                $script:mockAuthenticationId=$value;$reads=$script:bootReads;$rejected=$false
                try{Get-HibernateSessionEvidence | Out-Null}catch{$rejected=$true}
                Emit ($rejected -and $script:bootReads -eq $reads) 'collector rejects reserved service or anonymous LUID before boot query'
            }
            $script:mockAuthenticationId='0000000000000100'
            function Test-HibernateInteractiveMembership {param($Principal) return $false}
            $reads=$script:bootReads;$rejected=$false;try{Get-HibernateSessionEvidence | Out-Null}catch{$rejected=$true}
            Emit ($rejected -and $script:bootReads -eq $reads) 'collector rejects token without enabled interactive membership before boot query'
            foreach($case in @(
                @{field='vmId';value='foreign'},@{field='schema';value=2},@{field='mode';value='Capture'},
                @{field='status';value='Requested'},@{field='testOnly';value='true'},@{field='eventRecordId';value='100'},
                @{field='eventRecordId';value=0},@{field='utc';value='malformed'},@{field='utc';value='2026-10-07T08:00:00.0000000Z'}
            )){
                $changed=New-Baseline;$changed[$case.field]=$case.value
                Emit (!(Get-HibernateResumeDecision $changed $session $events $vmId $now).resumeVerified) ('snapshot field rejected '+$case.field+'='+$case.value)
            }
            foreach($case in @(
                @{provider='Microsoft-Windows-Kernel-General';id=12},@{provider='Microsoft-Windows-Kernel-Power';id=41},
                @{provider='Microsoft-Windows-WER-SystemErrorReporting';id=1001},@{provider='Microsoft-Windows-Eventlog';id=104}
            )){
                $extra=ConvertFrom-HibernateEventXml (New-EventXml $case.provider $case.id 103 '2026-10-09T08:02:02.0000000Z' '')
                Emit (!(Get-HibernateResumeDecision $baseline $session @($events[0],$events[1],$extra) $vmId $now).resumeVerified) ('boot crash or log-clear rejected '+$case.provider+'/'+$case.id)
            }
            foreach($index in @(0,1)){
                foreach($field in @('TargetState','EffectiveState')){
                    $changed=New-Events;$changed[$index].data[$field]='4'
                    Emit (!(Get-HibernateResumeDecision $baseline $session $changed $vmId $now).resumeVerified) ('S3 or fast-startup state rejected event='+$index+' field='+$field)
                }
            }
            foreach($case in @(
                @{index=0;field='recordId';value=[long]100},@{index=0;field='recordId';value=[long]103},
                @{index=1;field='recordId';value=[long]101},@{index=0;field='utc';value='2026-10-09T07:59:59.0000000Z'},
                @{index=1;field='utc';value='2026-10-09T08:04:00.0000000Z'}
            )){
                $changed=New-Events;$changed[$case.index][$case.field]=$case.value
                Emit (!(Get-HibernateResumeDecision $baseline $session $changed $vmId $now).resumeVerified) ('stale future duplicate or inverted record rejected '+$case.index+'/'+$case.field+'/'+$case.value)
            }
            foreach($case in @(
                @{field='SleepTime';value='2026-10-09T07:59:59.0000000Z'},@{field='SleepTime';value='2026-10-09T08:01:00.0000000Z'},
                @{field='WakeTime';value='2026-10-09T08:00:04.0000000Z'},@{field='WakeTime';value='2026-10-09T08:04:00.0000000Z'},
                @{field='WakeTime';value='malformed'}
            )){
                $changed=New-Events;$changed[1].data[$case.field]=$case.value
                Emit (!(Get-HibernateResumeDecision $baseline $session $changed $vmId $now).resumeVerified) ('unpaired timestamp rejected '+$case.field+'/'+$case.value)
            }
            $changed=New-Events;$changed[1].utc='2026-10-09T08:02:10.0000000Z';$changed[1].data.WakeTime='2026-10-09T08:00:06.0000000Z'
            Emit (!(Get-HibernateResumeDecision $baseline $session $changed $vmId $now).resumeVerified) 'wake reporting delay over 120 seconds rejected'
            Emit (!(Get-HibernateResumeDecision $baseline $session @($events[0]) $vmId $now).resumeVerified) 'sleep-only evidence rejected'
            Emit (!(Get-HibernateResumeDecision $baseline $session @($events[1]) $vmId $now).resumeVerified) 'wake-only evidence rejected'
            Emit (!(Get-HibernateResumeDecision $baseline $session @($events[0],$events[1],$events[1]) $vmId $now).resumeVerified) 'ambiguous repeated wake rejected'
            Emit (!(Get-HibernateResumeDecision $baseline $session (@($events[0]) * 128) $vmId $now).resumeVerified) '128 event bound rejects incomplete evidence'
            Emit (!(Get-HibernateResumeDecision $baseline $session $events $vmId 'malformed').resumeVerified) 'invalid verification timestamp rejected'
            $validXml=New-EventXml 'Microsoft-Windows-Kernel-Power' 42 101 '2026-10-09T08:00:05.0000000Z' '<Data Name="TargetState">5</Data>'
            foreach($text in @('broken XML',('x'*65537),($validXml.Replace('</EventData>','<Data Name="TargetState">5</Data></EventData>')),
                ($validXml.Replace('Microsoft-Windows-Kernel-Power','Foreign-Provider')),($validXml.Replace('<EventRecordID>101</EventRecordID>','<EventRecordID>-1</EventRecordID>')),
                ('<!DOCTYPE Event [<!ENTITY unsafe "unsafe">]>'+$validXml))){
                $rejected=$false;try{ConvertFrom-HibernateEventXml $text | Out-Null}catch{$rejected=$true}
                Emit $rejected 'malformed oversized duplicate foreign negative or DTD XML rejected'
            }
            function Get-WinEvent {param($FilterHashtable,$MaxEvents,$ErrorAction)
                if($MaxEvents -ne 128 -or $FilterHashtable.LogName -cne 'System' -or
                    $FilterHashtable.ProviderName -notcontains 'Microsoft-Windows-Power-Troubleshooter'){throw 'Unbounded event request.'}
                return $script:mockEvents
            }
            $script:mockEvents=@();Emit (@(Get-HibernateEvents ([pscustomobject](New-Baseline))).Count -eq 0) 'bounded query accepts no evidence without pretending success'
            $script:mockEvents=@([pscustomobject]@{})*128
            $rejected=$false;try{Get-HibernateEvents ([pscustomobject](New-Baseline)) | Out-Null}catch{$rejected=$true}
            Emit $rejected 'event query cap rejected before XML conversion'
            function Get-OutputPath {param($Name) return $Name}
            function Test-Path {param($LiteralPath)
                if($LiteralPath -ceq 'hibernate-snapshot.json'){return $script:existsSnapshot};return $script:existsLog
            }
            function New-Result {throw 'Fresh hibernate baseline reached read stage.'}
            function Assert-OneSesDevice {throw 'Retry must not read devices.'}
            function Invoke-BoundedTool {throw 'No power tool may execute in inert fixtures.'}
            foreach($case in @(@{snapshot=$true;log=$false},@{snapshot=$false;log=$true},@{snapshot=$true;log=$true},@{snapshot=$false;log=$false})){
                $script:existsSnapshot=$case.snapshot;$script:existsLog=$case.log
                $message='';try{& ([ScriptBlock]::Create($body))}catch{$message=$_.Exception.Message}
                $expected=if($case.snapshot -or $case.log){'Preserving the first hibernate baseline:*'}else{'Fresh hibernate baseline reached read stage.'}
                Emit ($message -like $expected) ('inert prepare guard snapshot='+$case.snapshot+' log='+$case.log)
            }
            function Get-OutputPath {param($Name) return (Join-Path $fixtureDirectory $Name)}
            function Assert-TrustedGuestAcl {param($Path)}
            function Write-Serial {param($Tag,$Value)}
            $first=New-Baseline;Write-FirstHibernateSnapshot $first
            $path=Join-Path $fixtureDirectory 'hibernate-snapshot.json';$original=[IO.File]::ReadAllBytes($path)
            $rejected=$false;try{Write-FirstHibernateSnapshot @{replacement=$true}}catch{$rejected=$true}
            Emit ($rejected -and [Convert]::ToBase64String($original) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'atomic CreateNew preserves original baseline on retry'
            # Extracted verify mode with only inert inputs validates wiring:
            # no resume proof means no capture; proof alone cannot pass capture.
            $VmId=[Guid]$vmId;$system32='C:\inert-system32';$acceptanceRoot='C:\inert-acceptance';$manifest=@{}
            $script:mockFailure=''
            function New-Result {param($Status) return [ordered]@{status=$Status}}
            function Get-OutputPath {param($Name) return $Name}
            function Test-Path {param($LiteralPath) return $false}
            function Assert-TrustedGuestAcl {param($Path)
                if($script:mockFailure -ceq 'acl' -and $Path -ceq 'hibernate-snapshot.json'){throw 'inert snapshot ACL failure'}
            }
            function Get-FileHash {param($LiteralPath,$Algorithm)
                $hash=if($script:mockFailure -ceq 'hash'){'b'*64}else{'a'*64};return [pscustomobject]@{Hash=$hash}
            }
            function Get-HibernateSessionEvidence {return (New-Session)}
            function Get-HibernateEvents {param($Snapshot)
                if($script:mockFailure -ceq 'eventquery'){throw 'inert event query failure'};return @()
            }
            function Get-HibernateResumeDecision {param($Snapshot,$Session,$Events,$ExpectedVmId,$NowUtc) return @{resumeVerified=$script:mockResume;status='Findings'}}
            function Assert-OneSesDevice {return [pscustomobject]@{ConfigManagerErrorCode=0;DeviceID='ROOT\MEDIA\0000';Service='SesMicrophone'}}
            function Assert-Inventory {param($Manifest,$Names,$Root)}
            function Invoke-BoundedTool {param($Executable,$Arguments,$LogName,$DeadlineSeconds)
                if($Executable -notlike '*ses_driver_capture_lab_tests.exe' -or $LogName -cne 'hibernate-capture.log'){throw 'Only inert capture is permitted.'}
                $script:captureCalls++;return @{exitCode=0;timedOut=$false;outputLimited=$false}
            }
            function Read-BoundedJson {param($Path,$Within,$Limit)
                if($Path -ceq 'hibernate-snapshot.json'){
                    if($script:mockFailure -ceq 'snapshot'){throw 'inert snapshot parsing failure'}
                    $saved=New-Baseline;$saved.session=[pscustomobject]$saved.session;$saved.powercfgSha256=('a'*64)
                    $saved.device=@{instanceId='ROOT\MEDIA\0000';service='SesMicrophone'};return [pscustomobject]$saved
                }
                if($script:mockFailure -ceq 'capturejson'){throw 'inert missing capture JSON'}
                return @{schema=1;checks=30;failures=0;unsupported=0;verified_endpoints=1;formats_passed=2;self_tests=$script:mockSelfTests}
            }
            function Write-Report {param($Name,$Value)
                $script:reportWrites++;$script:lastReport=[ordered]@{status=$Value.status;resumeVerified=$Value.resumeVerified}
            }
            foreach($case in @(@{resume=$false;selfTests=0;calls=0;status='Findings'},@{resume=$true;selfTests=0;calls=1;status='Passed'},@{resume=$true;selfTests=1;calls=1;status='Findings'})){
                $script:mockResume=$case.resume;$script:mockSelfTests=$case.selfTests;$script:captureCalls=0;$script:lastReport=$null;$script:reportWrites=0
                & ([ScriptBlock]::Create("switch ('fixture') { 'fixture' {"+$verifyBody+"} }"))
                Emit ($script:captureCalls -eq $case.calls -and $script:lastReport.status -ceq $case.status) ('inert verify wiring resume='+$case.resume+' captureSelfTests='+$case.selfTests)
            }
            foreach($failure in @('snapshot','acl','hash','eventquery','capturejson')){
                $script:mockFailure=$failure;$script:mockResume=$true;$script:mockSelfTests=0;$script:captureCalls=0;$script:reportWrites=0
                $script:lastReport=[ordered]@{status='Passed';resumeVerified=$true};$message=''
                try{& ([ScriptBlock]::Create("switch ('fixture') { 'fixture' {"+$verifyBody+"} }"))}catch{$message=$_.Exception.Message}
                $expected=@{snapshot='inert snapshot parsing failure';acl='inert snapshot ACL failure';
                    hash='Original hibernate capability evidence changed.';eventquery='inert event query failure';capturejson='inert missing capture JSON'}[$failure]
                $expectedCalls=if($failure -ceq 'capturejson'){1}else{0}
                Emit ($message -ceq $expected -and $script:reportWrites -eq 1 -and $script:lastReport.status -ceq 'Findings' -and
                    !$script:lastReport.resumeVerified -and $script:captureCalls -eq $expectedCalls) ('repeat failure resets prior Passed and propagates '+$failure)
            }
        }).AddArgument($hibernateSource).AddArgument($hibernateBody).AddArgument($hibernateVerifyBody).AddArgument($fixture)
        $hibernateResults=@($hibernateRunspace.Invoke())
        if($hibernateRunspace.Streams.Error.Count -gt 0){throw ('Inert hibernate fixtures failed: '+($hibernateRunspace.Streams.Error | Out-String))}
        Check ($hibernateResults.Count -eq 103) 'inert hibernate regression fixture inventory complete'
        foreach($hibernateResult in $hibernateResults){Check $hibernateResult.passed $hibernateResult.name}
    }finally{$hibernateRunspace.Dispose()}
    Reject {Assert-VmAcceptanceSeed $acceptanceSeed ([Guid]::NewGuid().ToString('D'))} 'acceptance seed for foreign VM rejected'
    [IO.File]::AppendAllText((Join-Path $acceptance 'ses_driver_capture_lab_tests.exe'),'tamper')
    Reject {Assert-VmAcceptanceSeed $acceptanceSeed $identity.id} 'tampered acceptance executable rejected'
    $acceptanceFiles['ses_driver_capture_lab_tests.exe']=(Get-FileHash -LiteralPath (Join-Path $acceptance 'ses_driver_capture_lab_tests.exe')).Hash.ToLowerInvariant();Save-Acceptance
    $foreignAcceptance=Join-Path $acceptance 'unexpected.ps1';[IO.File]::WriteAllText($foreignAcceptance,'inert')
    Reject {Assert-VmAcceptanceSeed $acceptanceSeed $identity.id} 'additional acceptance executable rejected'
    Remove-Item -LiteralPath $foreignAcceptance
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
    Check ($args[$args.IndexOf('-nic')+1] -ceq 'none') 'guest networking disconnected by default'
    Reject {Get-VmArguments $vm ([pscustomobject]$identity) -EvaluationActivationNetwork} 'activation network rejected for initial unattended ISO install'
    $networkArgs=Get-VmArguments $vm ([pscustomobject]$identity) -BootInstalled -EvaluationActivationNetwork
    Check (($networkArgs[$networkArgs.IndexOf('-nic')+1] -ceq 'user,model=e1000') -and !($networkArgs -match 'hostfwd|smb=|bridge|tap')) 'explicit evaluation activation uses fixed NAT without inbound forwarding or host shares'
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
    $writer=[PowerShell]::Create()
    try{
        $null=$writer.AddScript({param($common,$root,$directory)
            $ErrorActionPreference='Stop';. $common;$labSigningRoot=$root
            foreach($sequence in 1..100){Write-VmJson $directory 'process.json' @{sequence=$sequence}}
        }).AddArgument((Join-Path $PSScriptRoot 'driver-vm-common.ps1')).AddArgument($fixture).AddArgument($vm)
        $pending=$writer.BeginInvoke();$reads=0
        while(!$pending.IsCompleted){Read-VmJson $vm 'process.json' | Out-Null;$reads++}
        $writer.EndInvoke($pending) | Out-Null
        if($writer.HadErrors){throw 'Concurrent IPC writer failed'}
        Check ($reads -gt 0 -and (Read-VmJson $vm 'process.json').sequence -eq 100) 'concurrent IPC replacement and validated reads remain stable'
    }finally{$writer.Stop();$writer.Dispose()}
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
