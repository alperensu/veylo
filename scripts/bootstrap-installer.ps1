$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$toolRoot=Join-Path $root '.tools'
$compilerDirectory=Join-Path $toolRoot 'innosetup-7.1.0'
$download=Join-Path $toolRoot 'innosetup-7.1.0-x64.exe'
$expected='0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f'
New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
if(!(Test-Path -LiteralPath $download) -or (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){
    & curl.exe --fail --location --silent --show-error --retry 3 --output $download 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe'
    if($LASTEXITCODE -ne 0){throw 'Inno Setup download failed'}
}
if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'Inno Setup checksum mismatch'}
if(!(Test-Path -LiteralPath (Join-Path $compilerDirectory 'ISCC.exe'))){
    $signature=Get-AuthenticodeSignature -LiteralPath $download
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Pyrsys B\.V\.(,|$)'){throw 'Inno Setup publisher verification failed'}
    $arguments=@('/VERYSILENT','/SUPPRESSMSGBOXES','/SP-','/NORESTART','/CURRENTUSER','/NOICONS',('/DIR="'+$compilerDirectory+'"'))
    $taskProcess=Start-Process -FilePath $download -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden
    if($taskProcess.ExitCode -ne 0 -or !(Test-Path -LiteralPath (Join-Path $compilerDirectory 'ISCC.exe'))){throw 'Inno Setup compiler installation failed'}
}
Write-Output 'Inno Setup 7.1.0 available (official release SHA-256 verified)'
