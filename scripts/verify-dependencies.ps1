$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$lock=Get-Content -LiteralPath (Join-Path $root 'dependencies.lock.json') -Raw | ConvertFrom-Json
foreach($entry in $lock.files){
    $path=[IO.Path]::GetFullPath((Join-Path $root $entry.path))
    if(!$path.StartsWith($root+'\third_party\',[StringComparison]::OrdinalIgnoreCase)){throw 'Dependency path escapes third_party'}
    if(!(Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256){throw ('Dependency checksum mismatch: '+$entry.path)}
}
Write-Output ('Verified '+$lock.files.Count+' dependency source checksums')
