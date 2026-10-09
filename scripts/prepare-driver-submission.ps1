#Requires -Version 7.0
# Build an unsigned Microsoft submission draft only. No upload, signing or installation.
param([switch]$ValidateOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'driver-signing.ps1')

function Get-SubmissionTools {
    # Existing bootstrap.ps1 LLVM-MinGW 20260922 readers, never an executable from PATH.
    $llvm=Join-Path $driverSourceRoot '.tools/llvm-mingw-20260922-ucrt-x86_64/bin'
    $tools=[ordered]@{
        readobj=@{path=(Join-Path $llvm 'llvm-readobj.exe');sha256='15b6e2955cc15bade793dcd33770a7c294891ee9cc6a1ab754dd024c93649c97'}
        pdbutil=@{path=(Join-Path $llvm 'llvm-pdbutil.exe');sha256='1bbd2bb413bfaa6248312ba0e02e205fc4ecfce28e0fe222cfd6f4c5577a282c'}
    }
    foreach($tool in $tools.Values){
        Assert-LabPath $tool.path | Out-Null
        $info=Get-Item -LiteralPath $tool.path
        if($info.PSIsContainer -or $info.Length -lt 1 -or $info.Length -gt 64MB -or
           (Get-FileHash -LiteralPath $tool.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $tool.sha256){throw 'Pinned submission symbol reader mismatch'}
    }
    foreach($name in @('makecab','expand')){
        $path=Assert-LabPath (Join-Path $env:SystemRoot ('System32/'+$name+'.exe')) $env:SystemRoot
        $signature=Get-AuthenticodeSignature -LiteralPath $path
        if($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
           $signature.SignerCertificate.Subject -cne 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'){throw 'Untrusted Windows cabinet tool'}
        $tools[$name]=@{path=$path}
    }
    return $tools
}

function Invoke-SubmissionTool([string]$Executable,[string[]]$Arguments) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(!$process.Start()){throw 'Submission tool did not start'}
        $output=$process.StandardOutput.ReadToEndAsync();$errorOutput=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(30000)){
            $process.Kill($true);$process.WaitForExit(5000) | Out-Null
            throw 'Submission tool exceeded its 30-second deadline'
        }
        $stdout=$output.GetAwaiter().GetResult();$stderr=$errorOutput.GetAwaiter().GetResult()
        if($stdout.Length -gt 1MB -or $stderr.Length -gt 64KB){throw 'Oversized submission tool output'}
        if($process.ExitCode -ne 0){throw ('Submission tool rejected its input: '+[IO.Path]::GetFileName($Executable))}
        return $stdout
    }finally{$process.Dispose()}
}

function Assert-MatchingSubmissionSymbols([string]$SystemFile,[string]$SymbolFile,$Tools) {
    foreach($item in @(@{path=$SystemFile;max=16MB},@{path=$SymbolFile;max=64MB})){
        Assert-LabPath $item.path | Out-Null
        $info=Get-Item -LiteralPath $item.path
        if($info.PSIsContainer -or $info.Length -lt 1 -or $info.Length -gt $item.max){throw 'Invalid submission symbol input'}
    }
    $pe=Invoke-SubmissionTool $Tools.readobj.path @('--coff-debug-directory',$SystemFile)
    $pdb=Invoke-SubmissionTool $Tools.pdbutil.path @('dump','-summary',$SymbolFile)
    $guidPattern='\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
    $peGuid=[regex]::Matches($pe,'(?m)^\s*PDBGUID: ('+$guidPattern+')\r?$')
    $peAge=[regex]::Matches($pe,'(?m)^\s*PDBAge: ([0-9]+)\r?$')
    $pdbGuid=[regex]::Matches($pdb,'(?m)^\s*GUID: ('+$guidPattern+')\r?$')
    $pdbAge=[regex]::Matches($pdb,'(?m)^\s*Age: ([0-9]+)\r?$')
    if($pe -notmatch '(?m)^Format: COFF-x86-64\r?$' -or
       [regex]::Matches($pe,'(?m)^\s*PDBSignature: 0x53445352\r?$').Count -ne 1 -or
       $peGuid.Count -ne 1 -or $peAge.Count -ne 1 -or $pdbGuid.Count -ne 1 -or $pdbAge.Count -ne 1 -or
       $pdb -notmatch '(?m)^\s*Has Debug Info: true\r?$' -or $pdb -notmatch '(?m)^\s*Is stripped: false\r?$'){throw 'Expected one real RSDS record and a full PDB'}
    $guid=([Guid]$peGuid[0].Groups[1].Value).ToString('D')
    $age=[uint32]::Parse($peAge[0].Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
    if($age -eq 0 -or $guid -cne ([Guid]$pdbGuid[0].Groups[1].Value).ToString('D') -or
       $age -ne [uint32]::Parse($pdbAge[0].Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)){throw 'SYS CodeView GUID/age does not match its PDB'}
    return @{status='passed-guid-and-age';guid=$guid;age=$age}
}

function Get-SubmissionCabinetInventory([string]$Cabinet,[string[]]$Names,$Hashes,[string]$Stage) {
    Assert-LabPath $Cabinet | Out-Null
    $info=Get-Item -LiteralPath $Cabinet
    if($info.PSIsContainer -or $info.Length -lt 44 -or $info.Length -gt 128MB){throw 'Invalid submission cabinet size'}
    $bytes=[IO.File]::ReadAllBytes($Cabinet)
    # One cabinet, no external continuations/reserve headers. Parse CFFILE names
    # before decompression so only the exact four bounded relative paths reach expand.
    if([Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'MSCF' -or
       [BitConverter]::ToUInt32($bytes,8) -ne $bytes.Length -or
       $bytes[24] -ne 3 -or $bytes[25] -ne 1 -or [BitConverter]::ToUInt16($bytes,30) -ne 0 -or
       [BitConverter]::ToUInt16($bytes,28) -ne $Names.Count){throw 'Unexpected submission cabinet header'}
    $folders=[BitConverter]::ToUInt16($bytes,26)
    if($folders -lt 1 -or $folders -gt $Names.Count -or 36+$folders*8 -gt $bytes.Length){throw 'Unexpected cabinet folder count'}
    $cursor=[long][BitConverter]::ToUInt32($bytes,16);$dataStart=[long]$bytes.Length
    for($folder=0;$folder -lt $folders;$folder++){
        $offset=36+$folder*8;$data=[long][BitConverter]::ToUInt32($bytes,$offset)
        if($data -ge $bytes.Length -or [BitConverter]::ToUInt16($bytes,$offset+4) -eq 0 -or
           [BitConverter]::ToUInt16($bytes,$offset+6) -ne 1){throw 'Invalid MSZIP cabinet folder'}
        $dataStart=[Math]::Min($dataStart,$data)
    }
    if($cursor -lt 36+$folders*8 -or $cursor -ge $dataStart){throw 'Invalid cabinet file-table offset'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$inventory=@()
    foreach($unused in $Names){
        if($cursor+16 -ge $dataStart){throw 'Truncated cabinet file record'}
        $length=[BitConverter]::ToUInt32($bytes,[int]$cursor)
        if([BitConverter]::ToUInt16($bytes,[int]$cursor+8) -ge $folders){throw 'External or invalid cabinet member'}
        $cursor+=16;$end=$cursor
        while($end -lt $dataStart -and $end-$cursor -le 128 -and $bytes[$end] -ne 0){$end++}
        if($end -ge $dataStart -or $end-$cursor -gt 128){throw 'Unbounded cabinet member name'}
        $name=[Text.Encoding]::ASCII.GetString($bytes,[int]$cursor,[int]($end-$cursor));$cursor=$end+1
        $leaf=if($name.StartsWith('VeyloMic\',[StringComparison]::Ordinal)){$name.Substring(9)}else{''}
        if($leaf -cnotin $Names -or $name -cne ('VeyloMic\'+$leaf) -or !$seen.Add($name) -or
           $length -ne (Get-Item -LiteralPath (Join-Path $Stage $leaf)).Length -or
           $Hashes[$leaf] -cnotmatch '^[0-9a-f]{64}$'){throw 'Unexpected cabinet path, duplicate, or member size'}
        $inventory+= $name
    }
    return $inventory
}

$packet=Assert-LabPath (Join-Path $driverSourceRoot 'build/driver/package')
$manifest=Assert-TestSigningInput $packet
$sourceManifestHash=(Get-FileHash -LiteralPath (Join-Path $packet 'development-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
$pdb=Assert-LabPath (Join-Path $driverSourceRoot 'build/driver/bin/SesMicrophone.pdb')
$tools=Get-SubmissionTools
$symbolMatch=Assert-MatchingSubmissionSymbols (Join-Path $packet 'SesMicrophone.sys') $pdb $tools
$pdbHash=(Get-FileHash -LiteralPath $pdb -Algorithm SHA256).Hash.ToLowerInvariant()
if($ValidateOnly){Write-Output ('PASS fixed unsigned source/kit contract and real SYS/PDB GUID/age '+$symbolMatch.guid+'/'+$symbolMatch.age+'; no cabinet created');return}
$run=Assert-LabPath (Join-Path $driverSourceRoot ('artifacts/driver-submission/'+[Guid]::NewGuid().ToString('N'))) (Join-Path $driverSourceRoot 'artifacts') -MayNotExist
if(Test-Path -LiteralPath $run){throw 'Submission output directory already exists'}
New-Item -ItemType Directory -Path $run | Out-Null
$stage=Join-Path $run 'VeyloMic';New-Item -ItemType Directory -Path $stage | Out-Null
$names=@('SesMicrophone.inf','SesMicrophone.sys','SesMicrophone.cat','SesMicrophone.pdb')
foreach($name in $names){$source=if($name -eq 'SesMicrophone.pdb'){$pdb}else{Join-Path $packet $name};Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name)}
$hashes=[ordered]@{};foreach($name in $names){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $stage $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
foreach($name in $driverPayloadNames | Where-Object {$_ -ne 'SYSVAD-LICENSE'}){if($hashes[$name] -cne $manifest.files.$name){throw 'Submission snapshot differs from validated input'}}
if($hashes['SesMicrophone.pdb'] -cne $pdbHash){throw 'PDB changed while copying the submission snapshot'}
$symbolMatch=Assert-MatchingSubmissionSymbols (Join-Path $stage 'SesMicrophone.sys') (Join-Path $stage 'SesMicrophone.pdb') $tools
$ddf=Join-Path $run 'submission.ddf';$cabName='VeyloMic-'+$manifest.driverVersion+'-UNSIGNED-submission-draft.cab'
# Keep each CAB member's required subdirectory explicit and verify the actual
# CFFILE records afterward. Never interpolate user-supplied DDF code.
@('.OPTION EXPLICIT','.Set Cabinet=on','.Set Compress=on','.Set CompressionType=MSZIP','.Set MaxDiskSize=0',('.Set DiskDirectoryTemplate="'+$run+'"'),('.Set InfFileName="'+(Join-Path $run 'setup.inf')+'"'),('.Set RptFileName="'+(Join-Path $run 'setup.rpt')+'"'),('.Set CabinetNameTemplate='+$cabName))+@($names | ForEach-Object {'"'+(Join-Path $stage $_)+'" "VeyloMic\'+$_+'"'}) | Set-Content -LiteralPath $ddf -Encoding ascii
Invoke-SubmissionTool $tools.makecab.path @('/F',$ddf) | Set-Content -LiteralPath (Join-Path $run 'makecab.log') -Encoding utf8
$cab=Join-Path $run $cabName
$inventory=@(Get-SubmissionCabinetInventory $cab $names $hashes $stage)
$extracted=Join-Path $run 'cab-verified';New-Item -ItemType Directory -Path $extracted | Out-Null
Invoke-SubmissionTool $tools.expand.path @('-F:*',$cab,$extracted) | Set-Content -LiteralPath (Join-Path $run 'expand.log') -Encoding utf8
$files=@(Get-ChildItem -LiteralPath $extracted -Recurse -File -Force)
if($files.Count -ne $names.Count){throw 'Extracted cabinet inventory differs'}
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($file in $files){
    Assert-LabPath $file.FullName $extracted | Out-Null
    if($file.Name -cnotin $names -or !$seen.Add($file.Name) -or $file.Length -ne (Get-Item -LiteralPath (Join-Path $stage $file.Name)).Length -or
       (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hashes[$file.Name]){throw 'Extracted cabinet content hash mismatch'}
}
$signature=Get-AuthenticodeSignature -LiteralPath $cab
if($signature.Status -ne [Management.Automation.SignatureStatus]::NotSigned){throw 'Unexpected signed submission draft'}
@{schema=1;kind='Unsigned Microsoft submission draft';driverVersion=$manifest.driverVersion;appVersion=$manifest.appVersion;abi=$manifest.abi;protocol=$manifest.protocol;sourceManifestSha256=$sourceManifestHash;files=$hashes;pdbMatch=$symbolMatch;cabInventory=$inventory;cabContentsVerified=$true;cabSha256=(Get-FileHash -LiteralPath $cab -Algorithm SHA256).Hash.ToLowerInvariant();evSigned=$false;submitted=$false;dailyUseReady=$false;pending=@('Isolated kernel acceptance','Hardware Developer Program/EV certificate','EV CAB signing and Microsoft submission','Returned Microsoft package verification')} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $run 'submission-manifest.json') -Encoding utf8
Write-Output $cab
Write-Output 'PASS real SYS/PDB GUID+age and exact four-file VeyloMic CAB inventory/content hashes. Unsigned draft only; EV signing and Microsoft submission remain external.'
