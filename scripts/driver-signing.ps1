$ErrorActionPreference='Stop'
$labSigningRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'driver-package.ps1')
$labPublicNames=@('SesMicrophone.inf','SesMicrophone.sys','SesMicrophone.cat','SYSVAD-LICENSE','lab-test.cer','ses_driver_lab_tests.exe','ses_driver_capture_lab_tests.exe','DRIVER.md','DRIVER-LAB.md','LICENSE','README-TEST-SIGNED.txt')

function Assert-LabPath([string]$Path,[string]$Within=$labSigningRoot,[switch]$MayNotExist) {
    $full=[IO.Path]::GetFullPath($Path)
    $parent=[IO.Path]::GetFullPath($Within).TrimEnd('\')
    if($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(3).Contains(':') -or
       (!$full.Equals($parent,[StringComparison]::OrdinalIgnoreCase) -and !$full.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Lab path is outside its fixed root'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            # FileInfo.Attributes can become -1 when a concurrently replaced
            # file disappears, falsely looking like every attribute is set.
            # GetAttributes throws FileNotFound instead, allowing IPC readers
            # to retry absence without weakening the reparse-point rejection.
            if([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint){throw 'Lab paths cannot contain reparse points'}
        }elseif(!$MayNotExist -and $cursor -eq $full){throw 'Lab path is missing'}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Assert-LabInventory([string]$Directory,[string[]]$Required,[string[]]$Optional=@()) {
    $directory=Assert-LabPath $Directory
    if(!(Get-Item -LiteralPath $directory -Force).PSIsContainer){throw 'Expected a lab directory'}
    $entries=@(Get-ChildItem -LiteralPath $directory -Force)
    if($entries.Count -gt ($Required.Count+$Optional.Count)){throw 'Unexpected lab payload count'}
    foreach($entry in $entries){
        if($entry.Name -notin ($Required+$Optional) -or $entry.PSIsContainer -or
           ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $entry.Length -lt 1 -or $entry.Length -gt 16MB){throw ('Unexpected or oversized lab entry: '+$entry.Name)}
        Assert-LabPath $entry.FullName | Out-Null
    }
    foreach($name in $Required){if($entries.Name -notcontains $name){throw ('Missing lab payload: '+$name)}}
}

function Assert-TestSigningInput([string]$Directory) {
    # DRIVER.md is an optional existing unsigned-build document; it is never copied
    # from this input. Every signing payload name is fixed by this script.
    Assert-LabInventory $Directory ($driverPayloadNames+@('development-manifest.json')) @('DRIVER.md')
    $manifest=Assert-DevelopmentDriverPackage $Directory
    $kit=Get-Content -LiteralPath (Join-Path $labSigningRoot 'driver/ewdk.lock.json') -Raw | ConvertFrom-Json
    $upstream=Get-Content -LiteralPath (Join-Path $labSigningRoot 'driver/upstream.lock.json') -Raw | ConvertFrom-Json
    if($manifest.signed -isnot [bool] -or $manifest.dailyUseReady -isnot [bool] -or
       $manifest.kit -cne $kit.kit -or $manifest.kitSha256 -cne $kit.sha256 -or $manifest.sysvadCommit -cne $upstream.commit){throw 'Input signing provenance does not match the pinned source/kit'}
    return $manifest
}

function Get-LabSigningTools([string]$EwdkRoot) {
    if(!$EwdkRoot){throw 'Supply the already mounted, read-only pinned EWDK root with -EwdkRoot'}
    $full=[IO.Path]::GetFullPath($EwdkRoot)
    $drive=[IO.Path]::GetPathRoot($full)
    if($full.TrimEnd('\') -cne $drive.TrimEnd('\') -or ([IO.DriveInfo]::new($drive)).DriveType -ne [IO.DriveType]::CDRom){throw 'Lab signing requires the pinned EWDK on a read-only mounted ISO root'}
    Assert-LabPath $full $drive | Out-Null
    $lock=Get-Content -LiteralPath (Join-Path $labSigningRoot 'driver/ewdk.lock.json') -Raw | ConvertFrom-Json
    $iso=Assert-LabPath (Join-Path $labSigningRoot '.tools/ewdk/EWDK_26100.iso')
    $image=Get-DiskImage -ImagePath $iso
    $mountedVolumes=@($image | Get-Volume)
    if(!$image.Attached -or $image.Size -ne $lock.bytes -or $mountedVolumes.Count -ne 1 -or
       ($mountedVolumes[0].DriveLetter+':\') -cne $drive -or (Get-Item -LiteralPath $iso).Length -ne $lock.bytes -or
       (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash.ToLowerInvariant() -cne $lock.sha256){throw 'Mounted EWDK ISO does not match its exact pinned checksum'}
    $environment=Join-Path $full 'BuildEnv/SetupBuildEnv.cmd'
    Assert-LabPath $environment $drive | Out-Null
    if((Get-Item -LiteralPath $environment).Length -gt 64KB -or (Get-Content -LiteralPath $environment -Raw) -notmatch 'ge_release_svc_prod1.26100.6584'){throw 'Unpinned EWDK environment'}
    $tools=[ordered]@{
        signtool=@{path=(Join-Path $full 'Program Files/Windows Kits/10/bin/10.0.26100.0/x64/signtool.exe');sha256='010b6a17fd7803e3fc74af1f2e89bbd2bd225aab5f3368f4ed7d7ea4a09eb287'}
        inf2cat=@{path=(Join-Path $full 'Program Files/Windows Kits/10/bin/10.0.26100.0/x86/Inf2Cat.exe');sha256='b594728d38b271979367abc8060a971b8e42422738009be126710b1f5dd0fcbc'}
    }
    foreach($tool in $tools.Values){
        Assert-LabPath $tool.path $drive | Out-Null
        if((Get-Item -LiteralPath $tool.path).Length -gt 16MB -or (Get-FileHash -LiteralPath $tool.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $tool.sha256){throw 'Pinned signing tool checksum mismatch'}
    }
    return $tools
}

function New-LabPrivateDirectory([string]$Directory) {
    $directory=Assert-LabPath $Directory (Join-Path $labSigningRoot 'artifacts/driver-test-signing') -MayNotExist
    if(Test-Path -LiteralPath $directory){throw 'Private signing directory already exists'}
    New-Item -ItemType Directory -Path $directory | Out-Null
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $system=[Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null)
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true,$false)
    foreach($principal in @($owner,$system)){
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($principal,[Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $acl
    Assert-LabPrivateAcl $directory
    return $directory
}

function Assert-LabPrivateAcl([string]$Path) {
    Assert-LabPath $Path (Join-Path $labSigningRoot 'artifacts/driver-test-signing') | Out-Null
    $acl=Get-Acl -LiteralPath $Path
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $system='S-1-5-18'
    if(!$acl.AreAccessRulesProtected -and (Get-Item -LiteralPath $Path).PSIsContainer){throw 'Private directory ACL inheritance was not disabled'}
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $owner){throw 'Private signing path has the wrong owner'}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 2){throw 'Private signing ACL has an unexpected principal count'}
    foreach($rule in $rules){if($rule.IdentityReference.Value -notin @($owner,$system) -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'Private signing ACL is not owner/SYSTEM-only'}}
}

function Get-LabFileHashes([string]$Directory) {
    Assert-LabInventory $Directory $labPublicNames @('test-signing-manifest.json')
    $hashes=[ordered]@{}
    foreach($name in $labPublicNames){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $Directory $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
    return $hashes
}

function Assert-TestSignedLabManifest([string]$Directory) {
    Assert-LabInventory $Directory ($labPublicNames+@('test-signing-manifest.json'))
    $path=Join-Path $Directory 'test-signing-manifest.json'
    if((Get-Item -LiteralPath $path).Length -gt 64KB){throw 'Lab manifest is oversized'}
    $manifest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $contract=Get-DriverContract
    if($manifest.schema -ne 1 -or $manifest.kind -cne 'Veylo isolated lab test signing' -or
       $manifest.testOnly -isnot [bool] -or $manifest.testOnly -ne $true -or
       $manifest.signed -isnot [bool] -or $manifest.signed -ne $true -or
       $manifest.dailyUseReady -isnot [bool] -or $manifest.dailyUseReady -ne $false -or
       $manifest.microsoftProductionSigned -isnot [bool] -or $manifest.microsoftProductionSigned -ne $false -or
       $manifest.driverVersion -cne $contract.driverVersion -or $manifest.appVersion -cne $contract.appVersion -or
       $manifest.abi -ne $contract.abi -or $manifest.protocol -ne $contract.protocol -or
       $manifest.certificateThumbprint -cnotmatch '^[0-9a-f]{40}$' -or $manifest.certificateSha256 -cnotmatch '^[0-9a-f]{64}$' -or
       $manifest.sourceManifestSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Stale, invalid, or fabricated lab signing state'}
    $properties=@($manifest.files.PSObject.Properties)
    if($properties.Count -ne $labPublicNames.Count){throw 'Unexpected lab manifest payload count'}
    foreach($property in $properties){if($property.Name -cnotin $labPublicNames -or $property.Value -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid lab manifest payload entry'}}
    $source=@($manifest.unsignedSourceFiles.PSObject.Properties)
    if($source.Count -ne $driverPayloadNames.Count){throw 'Invalid unsigned-source inventory'}
    foreach($property in $source){if($property.Name -cnotin $driverPayloadNames -or $property.Value -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid unsigned-source payload entry'}}
    $hashes=Get-LabFileHashes $Directory
    foreach($name in $labPublicNames){if($manifest.files.$name -cne $hashes[$name]){throw ('Lab checksum mismatch: '+$name)}}
    $sourceInf=(Get-FileHash -LiteralPath (Join-Path $labSigningRoot 'driver/SesMicrophone.inf') -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hashes['SesMicrophone.inf'] -cne $sourceInf -or $manifest.unsignedSourceFiles.'SesMicrophone.inf' -cne $sourceInf){throw 'Lab INF does not match its exact source'}
    if($manifest.certificateSha256 -cne $hashes['lab-test.cer']){throw 'Public certificate checksum mismatch'}
    return $manifest
}

function Assert-LabArchive([string]$ArchivePath,[string]$Directory) {
    Assert-LabPath $ArchivePath | Out-Null
    $manifest=Assert-TestSignedLabManifest $Directory
    $expected=@($labPublicNames)+@('test-signing-manifest.json')
    $archive=[IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try{
        if($archive.Entries.Count -ne $expected.Count){throw 'Unexpected lab ZIP entry count'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($entry in $archive.Entries){
            if($entry.FullName -cnotin $expected -or !$seen.Add($entry.FullName) -or $entry.Length -lt 1 -or $entry.Length -gt 16MB){throw 'Unexpected, duplicate, or oversized lab ZIP entry'}
            $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
            $expectedHash=if($entry.FullName -eq 'test-signing-manifest.json'){(Get-FileHash -LiteralPath (Join-Path $Directory $entry.FullName) -Algorithm SHA256).Hash.ToLowerInvariant()}else{$manifest.files.($entry.FullName)}
            if($hash -cne $expectedHash){throw 'Lab ZIP content checksum mismatch'}
        }
    }finally{$archive.Dispose()}
}
