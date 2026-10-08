#ifndef AppVersion
  #error AppVersion must be supplied by build-installer.ps1
#endif
#ifndef PayloadDir
  #error PayloadDir must be supplied by build-installer.ps1
#endif
#ifndef OutputPath
  #error OutputPath must be supplied by build-installer.ps1
#endif
#ifdef TestFixture
  #define ProductName "Veylo Installer Test"
  #define ProductId "Veylo-Installer-Test"
  #define RunValue "Veylo-Installer-Test"
  #define SetupFile "Veylo-" + AppVersion + "-test-setup"
#else
  #define ProductName "Veylo"
  #define ProductId "{{830B48AF-2C5A-4DB8-9C5B-403E763D018E}"
  #define RunValue "SES"
  #define SetupFile "Veylo-" + AppVersion + "-win-x64-Setup"
#endif

[Setup]
AppId={#ProductId}
AppName={#ProductName}
AppVersion={#AppVersion}
AppPublisher=Veylo
AppPublisherURL=https://github.com/alperensu/veylo
AppSupportURL=https://github.com/alperensu/veylo/issues
AppUpdatesURL=https://github.com/alperensu/veylo/releases
DefaultDirName={localappdata}\Programs\{#ProductName}
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.19045
DisableProgramGroupPage=yes
DisableWelcomePage=no
WizardStyle=modern dynamic
SetupIconFile=..\app\Ses.Desktop\Assets\veylo.ico
UninstallDisplayIcon={app}\Veylo.exe
LicenseFile=..\LICENSE
OutputDir={#OutputPath}
OutputBaseFilename={#SetupFile}
Compression=lzma2
SolidCompression=yes
CloseApplications=no
RestartApplications=no
Uninstallable=yes
SetupLogging=yes

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
turkish.DesktopShortcut=Masaüstü kısayolu oluştur
english.DesktopShortcut=Create a desktop shortcut
turkish.LaunchApp=Veylo'yu aç
english.LaunchApp=Open Veylo
turkish.CloseApp=Veylo açık. Bildirim alanından Veylo'dan çık seçeneğiyle kapatıp tekrar dene.
english.CloseApp=Veylo is running. Exit Veylo from its notification-area menu and try again.
turkish.Intro=Yerel mikrofon iyileştirme. Bu geliştirme sürümü VB-CABLE ile ses iletir; kablo ve mikrofon sürücüsü kuruluma dahil değildir. Kayıtlı profiller ve kalibrasyonlar korunur.
english.Intro=Local microphone processing. This development build routes audio through VB-CABLE; no cable or microphone driver is installed. Saved profiles and calibrations are preserved.

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopShortcut}"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#ProductName}"; Filename: "{app}\Veylo.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\{#ProductName}"; Filename: "{app}\Veylo.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Veylo.exe"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent unchecked

[Code]
const RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

function VeyloRunning(): Boolean;
begin
  Result := CheckForMutexes('Local\SES-Desktop-' + GetUserNameString());
end;

procedure InitializeWizard();
begin
  WizardForm.WelcomeLabel2.Caption := CustomMessage('Intro');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if VeyloRunning() then Result := CustomMessage('CloseApp');
end;

function InitializeUninstall(): Boolean;
begin
  Result := not VeyloRunning();
  if not Result then SuppressibleMsgBox(CustomMessage('CloseApp'), mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var SavedCommand, ExpectedCommand, LatestCommand: String;
begin
  if CurUninstallStep <> usUninstall then Exit;
  ExpectedCommand := '"' + ExpandConstant('{app}\Veylo.exe') + '" --minimized';
  // Delete only this installed application's exact opt-in startup command.
  // A different portable target or user-edited value belongs to the user.
  if RegQueryStringValue(HKCU, RunKey, '{#RunValue}', SavedCommand) and
     (CompareText(SavedCommand, ExpectedCommand) = 0) then
    if RegQueryStringValue(HKCU, RunKey, '{#RunValue}', LatestCommand) and
       (LatestCommand = SavedCommand) then RegDeleteValue(HKCU, RunKey, '{#RunValue}');
  // No deletion of %LOCALAPPDATA%\SES: profiles/calibration survive uninstall.
end;
