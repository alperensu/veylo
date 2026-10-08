$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$reports=[IO.Path]::GetFullPath((Join-Path $root 'artifacts/installer'))
$install=[IO.Path]::GetFullPath((Join-Path $reports 'lifecycle'))
if(!$install.StartsWith($reports+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe installer test path'}
[xml]$project=Get-Content -LiteralPath (Join-Path $root 'app/Ses.Desktop/Ses.Desktop.csproj')
$version=[string]$project.Project.PropertyGroup.Version
$payload=Join-Path $root ('dist/Veylo-'+$version+'-win-x64')
$setup=Join-Path $reports ('fixture/Veylo-'+$version+'-test-setup.exe')
$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Veylo-Installer-Test_is1'
$runKey='Software\Microsoft\Windows\CurrentVersion\Run'
$testValue='Veylo-Installer-Test'
function ReadRun([string]$name){
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runKey)
    try{if($key -and $key.GetValueNames() -contains $name){return @{value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=$key.GetValueKind($name).ToString()} | ConvertTo-Json -Compress}}finally{if($key){$key.Dispose()}}
}
function StateHash {
    $state=Join-Path $env:LOCALAPPDATA 'SES/state.json'
    if(Test-Path -LiteralPath $state){return (Get-FileHash -LiteralPath $state -Algorithm SHA256).Hash}
}
function ExecuteSetup([string]$exe,[string[]]$arguments,[bool]$mustFail=$false){
    $taskProcess=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden
    if($mustFail){if($taskProcess.ExitCode -eq 0){throw 'Running-app guard failed'}}
    elseif($taskProcess.ExitCode -ne 0){throw ('Installer lifecycle failure: '+$taskProcess.ExitCode)}
}
if((Test-Path $uninstallKey) -or (ReadRun $testValue) -or (Test-Path -LiteralPath (Join-Path $install 'Veylo.exe'))){throw 'An installer test is already registered; remove that test installation before rerunning'}
if(Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'Veylo Installer Test.lnk')){throw 'Test shortcut already exists'}
$savedState=StateHash
$savedRun=ReadRun 'SES'
& (Join-Path $PSScriptRoot 'build-installer.ps1') -TestFixture
$arguments=@('/VERYSILENT','/SUPPRESSMSGBOXES','/SP-','/NORESTART',('/DIR="'+$install+'"'),('/LOG="'+(Join-Path $reports 'install.log')+'"'))
$uninstall=Join-Path $install 'unins000.exe'
$testKey=$null
try{
    ExecuteSetup $setup $arguments
    if(!(Test-Path $uninstallKey) -or (ReadRun $testValue)){throw 'Registration or startup-default check failed'}
    foreach($file in Get-ChildItem -LiteralPath $payload -Recurse -File){
        $relative=[IO.Path]::GetRelativePath($payload,$file.FullName)
        $installed=Join-Path $install $relative
        if(!(Test-Path -LiteralPath $installed) -or (Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $installed).Hash){throw ('Installed payload differs: '+$relative)}
    }
    $shortcut=Join-Path ([Environment]::GetFolderPath('Programs')) 'Veylo Installer Test.lnk'
    if(!(Test-Path -LiteralPath $shortcut)){throw 'Start Menu shortcut missing'}
    $shell=New-Object -ComObject WScript.Shell
    if($shell.CreateShortcut($shortcut).TargetPath -ne (Join-Path $install 'Veylo.exe')){throw 'Start Menu shortcut target differs'}
    $sentinel=Join-Path $install 'user-kept.txt'
    Set-Content -LiteralPath $sentinel -Value 'User-owned file must survive uninstall' -Encoding UTF8
    $testKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($runKey)
    $external='"C:\Portable\Veylo.exe" --minimized'
    $testKey.SetValue($testValue,$external,[Microsoft.Win32.RegistryValueKind]::String)
    ExecuteSetup $setup $arguments
    if($testKey.GetValue($testValue) -ne $external){throw 'Upgrade modified external startup target'}
    $mutexName='Local\SES-Desktop-'+[Environment]::UserName
    $created=$false
    $mutex=[Threading.Mutex]::new($false,$mutexName,[ref]$created)
    try{
        if(!$created){throw 'Veylo is running; installer tests will not interrupt it'}
        ExecuteSetup $setup $arguments $true
        ExecuteSetup $uninstall @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') $true
        if(!(Test-Path -LiteralPath (Join-Path $install 'Veylo.exe'))){throw 'Running-app rejection removed payload'}
    }finally{$mutex.Dispose()}
    $ui=Join-Path $reports 'installed-ui'
    ExecuteSetup (Join-Path $install 'Veylo.exe') @('--smoke','--out',('"'+$ui+'"'))
    if(!(Get-Content -LiteralPath (Join-Path $ui 'design-result.json') -Raw | ConvertFrom-Json).success){throw 'Installed app smoke failed'}
    ExecuteSetup $uninstall @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    if((Test-Path $uninstallKey) -or (Test-Path -LiteralPath (Join-Path $install 'Veylo.exe')) -or (Test-Path -LiteralPath $shortcut)){throw 'Uninstall left registered app components'}
    if($testKey.GetValue($testValue) -ne $external -or !(Test-Path -LiteralPath $sentinel)){throw 'Uninstall removed external startup target or user file'}
    $testKey.DeleteValue($testValue,$false)
    ExecuteSetup $setup $arguments
    $testKey.SetValue($testValue,('"'+(Join-Path $install 'Veylo.exe')+'" --minimized'),[Microsoft.Win32.RegistryValueKind]::String)
    ExecuteSetup $uninstall @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    if(ReadRun $testValue){throw 'Uninstall left owned startup target'}
    if((StateHash) -ne $savedState -or (ReadRun 'SES') -ne $savedRun){throw 'Installer tests modified real user settings/startup'}
    @{success=$true;version=$version;payloadMatches=$true;upgrade=$true;runningAppRejected=$true;installedOfflineSmoke=$true;externalStartupPreserved=$true;ownedStartupRemoved=$true;userFilesPreserved=$true;realSettingsUnchanged=$true;interactiveWizardValidated=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reports 'result.json') -Encoding UTF8
    Write-Output 'Installer lifecycle checks passed'
}finally{
    if($testKey){$testKey.DeleteValue($testValue,$false);$testKey.Dispose()}
}
