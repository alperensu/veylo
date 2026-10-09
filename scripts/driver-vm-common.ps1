# Private VM control: no sockets, arbitrary QMP or host devices.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'driver-signing.ps1')
$vmAllowedKeys=@('ret','esc','spc','tab','up','down','left','right','home','end','pgup','pgdn','backspace','delete','ctrl','alt','shift','meta_l','semicolon','slash','backslash','dot','apostrophe','grave_accent','bracket_left','bracket_right','minus','equal','comma')+@('a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z')+@('0','1','2','3','4','5','6','7','8','9')+@(1..12 | ForEach-Object {'f'+$_})
function Assert-VmPrivateAcl([string]$Path,[string]$Within) {
    $full=Assert-LabPath $Path $Within;$acl=Get-Acl -LiteralPath $full
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $owner){throw 'VM path has a different owner'}
    if((Get-Item -LiteralPath $full).PSIsContainer -and !$acl.AreAccessRulesProtected){throw 'VM directory inherits permissions'}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 2){throw 'VM ACL principal count differs'}
    foreach($rule in $rules){if($rule.IdentityReference.Value -cnotin @($owner,'S-1-5-18') -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'VM path is not owner/SYSTEM-only'}}
    return $full
}
function Assert-VmAcceptanceSeed([string]$Seed,[string]$VmId) {
    $directory=Assert-LabPath (Join-Path $Seed 'acceptance') $Seed
    Assert-LabPrivateAcl $directory
    $names=@('driver-vm-acceptance.ps1','ses_driver_capture_lab_tests.exe','acceptance-manifest.json')
    Assert-LabInventory $directory $names
    foreach($name in $names){Assert-LabPrivateAcl (Join-Path $directory $name)}
    $path=Join-Path $directory 'acceptance-manifest.json'
    if((Get-Item -LiteralPath $path).Length -gt 16KB){throw 'Oversized acceptance manifest'}
    $manifest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if($manifest.schema -ne 1 -or $manifest.testOnly -isnot [bool] -or !$manifest.testOnly -or $manifest.vmId -cne $VmId){throw 'Acceptance seed identity mismatch'}
    $entries=@($manifest.files.PSObject.Properties)
    if($entries.Count -ne 2){throw 'Acceptance inventory mismatch'}
    foreach($entry in $entries){
        if($entry.Name -cnotin $names[0..1] -or $entry.Value -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $directory $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){throw 'Acceptance payload checksum mismatch'}
    }
    return $directory
}
function Get-VmFirmwarePaths([string]$Vm,$State,[switch]$VerifyInputs) {
    $properties=@($State.PSObject.Properties.Name)
    $firmware=if($properties -contains 'firmware'){$State.firmware}else{'BIOS'}
    if($firmware -isnot [string] -or $firmware -cnotin @('BIOS','UEFI')){throw 'Invalid guest firmware enum'}
    if($firmware -ceq 'BIOS'){
        if($properties -contains 'firmwareCode' -or $properties -contains 'firmwareVars'){throw 'BIOS metadata cannot attach firmware paths'}
        return @{firmware='BIOS'}
    }
    $base=Join-Path $labSigningRoot '.tools/driver-lab'
    $ownedVm=Assert-VmPrivateAcl $Vm $base
    $code=Join-Path $base 'qemu/share/edk2-x86_64-code.fd'
    $vars=Join-Path $ownedVm 'uefi-vars.fd'
    if($properties -notcontains 'firmwareCode' -or $properties -notcontains 'firmwareVars' -or
       $State.firmwareCode -isnot [string] -or $State.firmwareVars -isnot [string] -or
       $State.firmwareCode -cne $code -or $State.firmwareVars -cne $vars){throw 'UEFI metadata must use fixed code and owned NVRAM paths'}
    $code=Assert-LabPath $code $base
    $vars=Assert-VmPrivateAcl $vars $ownedVm
    foreach($file in @($code,$vars)){
        if($file.Contains(',') -or $file.Contains('"')){throw 'Unsupported firmware path delimiter'}
        $info=Get-Item -LiteralPath $file
        if($info.PSIsContainer -or $info.Length -lt 1 -or $info.Length -gt 16MB){throw 'Invalid guest firmware file size/type'}
    }
    # NVRAM is mutable during guest boots. Its template is pinned at creation;
    # subsequent starts enforce fixed ownership/path and the exact flash size.
    if((Get-Item -LiteralPath $vars).Length -ne 540672){throw 'Guest NVRAM flash size differs'}
    if($VerifyInputs){
        $lock=Get-Content -LiteralPath (Join-Path $labSigningRoot 'driver/lab.lock.json') -Raw | ConvertFrom-Json
        if($lock.qemu.uefiCodeSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
           (Get-FileHash -LiteralPath $code -Algorithm SHA256).Hash.ToLowerInvariant() -cne $lock.qemu.uefiCodeSha256){throw 'Pinned UEFI code checksum mismatch'}
    }
    return @{firmware='UEFI';code=$code;vars=$vars}
}
function Get-VmInstallLayout([ValidateSet('BIOS','UEFI')][string]$Firmware='BIOS') {
    if($Firmware -eq 'UEFI'){
        # Microsoft's current Windows 11 GPT guidance requires ESP >=200 MB for
        # 512/512e and >=300 MB for 4Kn. Use 300 MB for this new guest disk only.
        return @{partitionId=3;
            create='<CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition><CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition><CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>';
            modify='<ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition><ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>VEYLO-LAB</Label><Letter>C</Letter></ModifyPartition>'}
    }
    return @{partitionId=1;
        create='<CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>';
        modify='<ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>VEYLO-LAB</Label><Letter>C</Letter><Active>true</Active></ModifyPartition>'}
}
function Get-OwnedVm([string]$Directory,[switch]$VerifyInputs) {
    $base=Join-Path $labSigningRoot '.tools/driver-lab';$vm=Assert-VmPrivateAcl $Directory $base
    if([IO.Path]::GetFileName($vm) -cnotmatch '^vm-[0-9a-f]{32}$'){throw 'Not an owned Veylo VM directory'}
    $metadata=Assert-VmPrivateAcl (Join-Path $vm 'vm.json') $vm
    if((Get-Item -LiteralPath $metadata).Length -gt 16KB){throw 'Oversized VM metadata'}
    $state=Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json;$id=[Guid]::Empty
    if($state.schema -ne 1 -or $state.ownedBy -cne 'Veylo isolated driver lab' -or ![Guid]::TryParseExact([string]$state.id,'D',[ref]$id) -or $id.ToString('D') -cne $state.id -or $state.accelerator -cnotin @('whpx','tcg') -or $state.hostSecurityChanged -isnot [bool] -or $state.hostSecurityChanged -or $state.installed -isnot [bool]){throw 'Invalid VM identity'}
    Get-VmFirmwarePaths $vm $state -VerifyInputs:$VerifyInputs | Out-Null
    # Ownership and canonical paths are mandatory even for control-only reads;
    # VerifyInputs adds immutable payload hashes and full seed inventory checks.
    $disk=Assert-VmPrivateAcl (Join-Path $vm 'windows.qcow2') $vm;$diskInfo=Get-Item -LiteralPath $disk
    if($state.disk -cne $disk -or $diskInfo.PSIsContainer -or $diskInfo.Length -lt 1 -or $diskInfo.Length -gt 80GB){throw 'Invalid owned virtual disk'}
    $seed=Assert-LabPath $state.seed (Join-Path $labSigningRoot 'artifacts/driver-test-signing');Assert-LabPrivateAcl $seed
    if(!(Get-Item -LiteralPath $seed).PSIsContainer){throw 'VM seed must be a private directory'}
    $iso=Assert-LabPath (Join-Path $base 'Windows11-IoT-LTSC-2024-eval.iso') $base
    $isoInfo=Get-Item -LiteralPath $iso
    if($state.iso -cne $iso -or $isoInfo.PSIsContainer -or $isoInfo.Length -lt 1 -or $isoInfo.Length -gt 8GB){throw 'Invalid fixed guest ISO path/size'}
    if($VerifyInputs){
        $seedPath=Assert-LabPath (Join-Path $seed 'veylo-lab-seed.json') $seed;Assert-LabPrivateAcl $seedPath
        if((Get-Item -LiteralPath $seedPath).Length -gt 64KB){throw 'Oversized seed metadata'}
        $identity=Get-Content -LiteralPath $seedPath -Raw | ConvertFrom-Json
        if($identity.schema -ne 1 -or $identity.testOnly -ne $true -or $identity.id -cne $state.id){throw 'Seed and VM identity differ'}
        $entries=@($identity.files.PSObject.Properties);$names=$labPublicNames+@('test-signing-manifest.json','devcon.exe','guest.ps1')
        if($entries.Count -ne $names.Count){throw 'Invalid fixed seed inventory'}
        foreach($entry in $entries){
            if($entry.Name -cnotin $names -or $entry.Value -cnotmatch '^[0-9a-f]{64}$'){throw 'Unexpected seed entry'}
            $file=Assert-LabPath (Join-Path $seed $entry.Name) $seed;Assert-LabPrivateAcl $file
            if((Get-Item -LiteralPath $file).Length -gt 16MB -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){throw 'Seed payload checksum mismatch'}
        }
        $inventory=@(Get-ChildItem -LiteralPath $seed -Force)
        $hasAcceptance=Test-Path -LiteralPath (Join-Path $seed 'acceptance')
        if($hasAcceptance){Assert-VmAcceptanceSeed $seed $state.id | Out-Null}
        if($inventory.Count -ne $names.Count+2+[int]$hasAcceptance){throw 'Unexpected seed files'}
        foreach($file in $inventory){
            if($file.Name -ceq 'acceptance' -and $hasAcceptance -and $file.PSIsContainer){continue}
            if($file.Name -cnotin ($names+@('veylo-lab-seed.json','autounattend.xml')) -or $file.PSIsContainer){throw 'Unexpected seed path'}
            Assert-LabPath $file.FullName $seed | Out-Null;Assert-LabPrivateAcl $file.FullName
        }
        $exe=Assert-LabPath (Join-Path $base 'qemu/qemu-system-x86_64.exe') $base
        $lock=Get-Content -LiteralPath (Join-Path $labSigningRoot 'driver/lab.lock.json') -Raw | ConvertFrom-Json
        foreach($item in @(@{path=$exe;hash=$lock.qemu.systemSha256},@{path=$iso;hash=$lock.windows.sha256})){
            if($item.hash -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.hash){throw 'Pinned VM input mismatch'}
        }
    }
    return @{directory=$vm;state=$state}
}
function Write-VmJson([string]$Directory,[string]$Name,$Value) {
    if($Name -cnotin @('process.json','command.json','response.json')){throw 'Unapproved VM output filename'}
    Assert-VmPrivateAcl $Directory (Join-Path $labSigningRoot '.tools/driver-lab') | Out-Null
    $path=Assert-LabPath (Join-Path $Directory $Name) $Directory -MayNotExist
    if(Test-Path -LiteralPath $path){Assert-VmPrivateAcl $path $Directory | Out-Null}
    $temporary=Assert-LabPath (Join-Path $Directory ('write-'+[Guid]::NewGuid().ToString('N')+'.tmp')) $Directory -MayNotExist
    $backup=Assert-LabPath (Join-Path $Directory ('previous-'+[Guid]::NewGuid().ToString('N')+'.tmp')) $Directory -MayNotExist
    try{
        [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
        # Elevated Windows tokens can default a new file's owner to Administrators.
        # Explicitly own only this newly created private temporary file; do not
        # weaken the ownership checks on existing paths or foreign files.
        $acl=Get-Acl -LiteralPath $temporary
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl -LiteralPath $temporary -AclObject $acl
        Assert-VmPrivateAcl $temporary $Directory | Out-Null
        if(Test-Path -LiteralPath $path){[IO.File]::Replace($temporary,$path,$backup)}else{[IO.File]::Move($temporary,$path)}
    }finally{foreach($item in @($temporary,$backup)){if(Test-Path -LiteralPath $item){Remove-Item -LiteralPath $item}}}
}
function Read-VmJson([string]$Directory,[string]$Name) {
    if($Name -cnotin @('process.json','command.json','response.json')){throw 'Unapproved VM input filename'}
    $deadline=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        try{
            $path=Assert-VmPrivateAcl (Join-Path $Directory $Name) $Directory
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            break
        }catch{
            # ReplaceFile can briefly hide or hold the name between metadata
            # lookup and opening. Retry absence/sharing only, never invalid ACL.
            $absent=$_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -or $_.Exception -is [Management.Automation.ItemNotFoundException] -or $_.Exception.GetBaseException() -is [IO.FileNotFoundException] -or $_.Exception.Message -ceq 'Lab path is missing'
            $base=$_.Exception.GetBaseException()
            $sharing=$base -is [IO.IOException] -and ($base.HResult -band 0xffff) -in @(32,33)
            if((!$absent -and !$sharing) -or $deadline.ElapsedMilliseconds -ge 1000){throw}
            Start-Sleep -Milliseconds 10
        }
    }
    # Allow atomic replacement while a reader holds the previous file. The
    # PowerShell provider's default sharing can reject Move(overwrite), which
    # used to terminate a healthy VM during concurrent command/response polls.
    try{
        if($stream.Length -gt 16KB){throw 'Oversized VM control message'}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true,1024,$true)
        try{
            $buffer=[char[]]::new(16385);$length=0
            while($length -lt $buffer.Length){$count=$reader.Read($buffer,$length,$buffer.Length-$length);if(!$count){break};$length+=$count}
            if($length -gt 16KB){throw 'Oversized VM control message'}
            $json=[string]::new($buffer,0,$length)
        }finally{$reader.Dispose()}
    }finally{$stream.Dispose()}
    # PowerShell 7.5+ otherwise coerces ISO timestamps into DateTime objects,
    # breaking exact process identity and the request's string contract.
    $jsonOptions=@{}
    if($PSVersionTable.PSVersion -ge [Version]'7.5'){$jsonOptions.DateKind='String'}
    return $json | ConvertFrom-Json @jsonOptions
}
function Get-VmArguments([string]$Vm,$State,[switch]$BootInstalled,[switch]$EvaluationActivationNetwork) {
    $firmware=Get-VmFirmwarePaths $Vm $State
    $diskBoot=$BootInstalled -or $State.installed
    if($EvaluationActivationNetwork -and !$diskBoot){throw 'Evaluation activation networking requires an explicitly installed guest disk'}
    if(!$diskBoot -and (Test-Path -LiteralPath (Join-Path $Vm 'process.json'))){throw 'Initial ISO boot is allowed once; use -BootInstalled to resume the owned disk'}
    foreach($path in @($State.disk,$State.iso,$State.seed,$Vm)){if($path.Contains(',') -or $path.Contains('"')){throw 'Unsupported VM path delimiter'}}
    # Optional user-mode NAT has no inbound forwarding, bridge, shared folders
    # or host devices. Use only for normal evaluation activation; omit to
    # restore the default disconnected guest on the next cold boot.
    $nic=if($EvaluationActivationNetwork){'user,model=e1000'}else{'none'}
    $arguments=@('-machine','q35','-accel',$State.accelerator,'-cpu','max','-smp','2','-m','6144','-display','none','-nic',$nic,'-monitor','none','-qmp','stdio','-no-reboot',
        '-serial',('file:'+(Join-Path $Vm 'serial.log')),'-smbios',('type=1,manufacturer=QEMU,product=VeyloDriverLab,uuid='+$State.id),
        '-drive',('file='+$State.disk+',format=qcow2,if=ide,index=0'))
    if($firmware.firmware -ceq 'UEFI'){
        # This non-secure OVMF policy applies only to the isolated guest. Never
        # change host firmware or attach an arbitrary caller-supplied flash file.
        $arguments+=@('-drive',('file='+$firmware.code+',format=raw,if=pflash,unit=0,readonly=on'),
            '-drive',('file='+$firmware.vars+',format=raw,if=pflash,unit=1'))
    }
    if(!$diskBoot){$arguments+=@('-drive',('file='+$State.iso+',media=cdrom,if=ide,index=2,readonly=on'))}
    $arguments+=@('-device','qemu-xhci','-drive',('file=fat:ro:'+$State.seed+',format=raw,if=none,id=seed,readonly=on'),'-device','usb-storage,drive=seed,removable=on','-boot',$(if($diskBoot){'order=c'}else{'order=c,once=d'}))
    return $arguments
}
function Get-VmCommand($Request,[string]$Vm,[string]$Session,[string]$Screen) {
    if(@($Request.PSObject.Properties).Count -ne 7 -or $Request.schema -ne 1 -or $Request.vmId -cne $Vm -or $Request.sessionId -cne $Session -or $Request.requestId -cnotmatch '^[0-9a-f]{32}$' -or $Request.command -cnotin @('query-status','screendump','send-key','quit') -or $Request.keys -isnot [array] -or $Request.keys.Count -gt 16 -or $Request.createdUtc -isnot [string]){throw 'Invalid VM control message'}
    $created=[DateTimeOffset]::MinValue
    if(![DateTimeOffset]::TryParseExact($Request.createdUtc,'O',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$created) -or [Math]::Abs(([DateTimeOffset]::UtcNow-$created).TotalSeconds) -gt 30){throw 'Stale VM control message'}
    if($Request.command -cne 'send-key' -and $Request.keys.Count){throw 'Keys allowed only for send-key'}
    $arguments=@{}
    if($Request.command -ceq 'screendump'){$arguments=@{filename=$Screen}}
    if($Request.command -ceq 'send-key'){
        if(!$Request.keys.Count){throw 'send-key requires allowlisted keys'}
        foreach($key in $Request.keys){if($key -isnot [string] -or $key -cnotin $vmAllowedKeys){throw 'Unapproved VM key'}}
        $arguments=@{keys=@($Request.keys | ForEach-Object {@{type='qcode';data=$_}});'hold-time'=100}
    }
    return @{execute=$Request.command;arguments=$arguments;id=$Request.requestId}
}
function Initialize-VmQmpTransport {
    if('VeyloLab.QmpProcess' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
namespace VeyloLab {
 public sealed class QmpProcess : IDisposable {
  readonly Process child=new Process();
  readonly BlockingCollection<string> lines=new BlockingCollection<string>(256);
  Task output,error;volatile string fault;
  public QmpProcess(string exe,string[] arguments,string log) {
   var info=new ProcessStartInfo(exe){UseShellExecute=false,CreateNoWindow=true,
    RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,
    StandardInputEncoding=new UTF8Encoding(false),StandardOutputEncoding=new UTF8Encoding(false),StandardErrorEncoding=new UTF8Encoding(false)};
   foreach(var arg in arguments)info.ArgumentList.Add(arg);child.StartInfo=info;
   if(!child.Start())throw new InvalidOperationException("QEMU process did not start");
   output=Task.Run(async()=>{
    try {
     var chars=new char[4096];var line=new StringBuilder();int n;
     while((n=await child.StandardOutput.ReadAsync(chars,0,chars.Length))>0) {
      for(int i=0;i<n;i++) {
       if(chars[i]=='\n') {if(!lines.TryAdd(line.ToString().TrimEnd('\r')))throw new IOException("QMP queue limit");line.Clear();}
       else {if(line.Length>=65536)throw new IOException("QMP message limit");line.Append(chars[i]);}
      }
     }
    }catch {fault="QMP output failed or exceeded its bound";Terminate();}finally{lines.CompleteAdding();}
   });
   error=Task.Run(async()=>{
    try {
     using(var file=new FileStream(log,FileMode.Create,FileAccess.Write,FileShare.Read)) {
      var buffer=new char[4096];long remaining=1048576;int n;
      while((n=await child.StandardError.ReadAsync(buffer,0,buffer.Length))>0) {
       var bytes=Encoding.UTF8.GetBytes(buffer,0,n);int count=(int)Math.Min(bytes.Length,remaining);
       if(count>0){await file.WriteAsync(bytes,0,count);remaining-=count;await file.FlushAsync();}
      }
     }
    }catch {fault="Bounded QEMU stderr capture failed";Terminate();}
   });
  }
  public int Id {get{return child.Id;}}
  public string StartTimeUtc {get{return child.StartTime.ToUniversalTime().ToString("O");}}
  public bool HasExited {get{return child.HasExited;}}
  public string Fault {get{return fault;}}
  public string ReadLine(int milliseconds) {
   string value;if(lines.TryTake(out value,milliseconds))return value;
   if(fault!=null)throw new IOException(fault);throw new TimeoutException("QMP reply deadline exceeded");
  }
  public bool TryRead(out string value){return lines.TryTake(out value);}
  public void WriteLine(string message) {
   if(message.Length>4096||child.HasExited)throw new IOException("QMP input rejected");
   child.StandardInput.WriteLine(message);child.StandardInput.Flush();
  }
  public bool WaitForExit(int milliseconds){return child.WaitForExit(milliseconds);}
  public void Terminate(){try{if(!child.HasExited)child.Kill(true);}catch{}}
  public void Dispose(){Terminate();try{child.WaitForExit(2000);}catch{}try{Task.WaitAll(new[]{output,error},1000);}catch{}child.Dispose();}
 }
}
'@
}
function Invoke-VmQmp($Transport,$Command,[int]$TimeoutMs=3000) {
    $Transport.WriteLine(($Command | ConvertTo-Json -Depth 6 -Compress));$clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.ElapsedMilliseconds -lt $TimeoutMs){
        $reply=$Transport.ReadLine([Math]::Max(1,$TimeoutMs-[int]$clock.ElapsedMilliseconds)) | ConvertFrom-Json
        if($reply.id -ceq $Command.id){
            if($reply.PSObject.Properties.Name -contains 'error'){throw 'QMP rejected an allowlisted operation'}
            if($reply.PSObject.Properties.Name -notcontains 'return'){throw 'Malformed QMP response'}
            return $reply.return
        }
        if($reply.PSObject.Properties.Name -notcontains 'event'){throw 'Unexpected QMP message'}
    }
    throw 'QMP response deadline exceeded'
}
function Connect-VmQmp($Transport) {
    $greeting=$Transport.ReadLine(5000) | ConvertFrom-Json
    if($greeting.PSObject.Properties.Name -notcontains 'QMP'){throw 'Missing QMP greeting'}
    Invoke-VmQmp $Transport @{execute='qmp_capabilities';id='capabilities'} | Out-Null
    $status=Invoke-VmQmp $Transport @{execute='query-status';id='startup'}
    if($Transport.HasExited -or !$status.status){throw 'QEMU exited during startup'}
    return $status
}
