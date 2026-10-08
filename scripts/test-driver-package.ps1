$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'driver-package.ps1')
$fixture=Join-Path $root ('artifacts/driver-package-tests/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $fixture | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'driver/SesMicrophone.inf') -Destination $fixture
# Non-loadable dummy bytes test manifest integrity only, never driver signing.
foreach($name in @('SesMicrophone.sys','SesMicrophone.cat','SYSVAD-LICENSE')){[IO.File]::WriteAllBytes((Join-Path $fixture $name),[byte[]](1,2,3,4))}
$checks=0
function Reject([string]$Name,[scriptblock]$Action){
    $rejected=$false
    try{& $Action | Out-Null}catch{$rejected=$true}
    if(!$rejected){throw ('Accepted invalid package: '+$Name)}
    $script:checks++;Write-Output ('PASS '+$Name)
}
New-DevelopmentDriverManifest $fixture
$first=Get-Content -LiteralPath (Join-Path $fixture 'development-manifest.json') -Raw
New-DevelopmentDriverManifest $fixture
$second=Get-Content -LiteralPath (Join-Path $fixture 'development-manifest.json') -Raw
if($first -cne $second){throw 'Repeated manifest generation changed its own inventory'}
$manifest=Assert-DevelopmentDriverPackage $fixture
if($manifest.files.PSObject.Properties.Name.Count -ne 4 -or $manifest.files.PSObject.Properties.Name -contains 'development-manifest.json'){throw 'Manifest included stale/self-referential files'}
$checks++;Write-Output 'PASS repeated manifest generation excludes itself and stale files'
[IO.File]::WriteAllBytes((Join-Path $fixture 'SesMicrophone.sys'),[byte[]](9,9))
Reject 'modified kernel payload rejected' {Assert-DevelopmentDriverPackage $fixture}
[IO.File]::WriteAllBytes((Join-Path $fixture 'SesMicrophone.sys'),[byte[]](1,2,3,4))
$manifest.abi=999;$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fixture 'development-manifest.json')
Reject 'stale ABI rejected' {Assert-DevelopmentDriverPackage $fixture}
New-DevelopmentDriverManifest $fixture
$manifest=Assert-DevelopmentDriverPackage $fixture
$manifest.files | Add-Member -NotePropertyName '../outside.sys' -NotePropertyValue ('a'*64)
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fixture 'development-manifest.json')
Reject 'extra/path traversal manifest entry rejected' {Assert-DevelopmentDriverPackage $fixture}
New-DevelopmentDriverManifest $fixture
$manifest=Assert-DevelopmentDriverPackage $fixture;$manifest.signed=$true
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fixture 'development-manifest.json')
Reject 'fabricated signed development state rejected' {Assert-DevelopmentDriverPackage $fixture}
Set-Content -LiteralPath (Join-Path $fixture 'SesMicrophone.inf') -Value 'unexpected INF'
Reject 'foreign INF rejected before manifest generation' {New-DevelopmentDriverManifest $fixture}
Copy-Item -LiteralPath (Join-Path $root 'driver/SesMicrophone.inf') -Destination $fixture -Force
$file=[IO.File]::OpenWrite((Join-Path $fixture 'SesMicrophone.sys'));try{$file.SetLength(16MB+1)}finally{$file.Dispose()}
Reject 'oversized kernel payload rejected' {New-DevelopmentDriverManifest $fixture}
Remove-Item -LiteralPath (Join-Path $fixture 'SesMicrophone.sys')
Reject 'missing kernel payload rejected' {New-DevelopmentDriverManifest $fixture}
Write-Output "$checks manifest integrity checks passed; no driver or certificates installed"
