#define AppName "Codex Profile Switcher"
#define AppVersion GetEnv("CODEX_SWITCHER_VERSION")
#define AppPublisher "Codex Profile Switcher contributors"
#define AppId "{{9D9E1F65-39F2-4CC4-9B3D-67AD77A54D7D}}"
#define SourceDir GetEnv("CODEX_SWITCHER_SOURCE")
#define OutputDir GetEnv("CODEX_SWITCHER_OUTPUT")

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/IIMovoMII/Codex-Profile-Switcher
AppSupportURL=https://github.com/IIMovoMII/Codex-Profile-Switcher/issues
DefaultDirName={localappdata}\Programs\CodexProfileSwitcher
DefaultGroupName=Codex Profile Switcher
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Codex-Profile-Switcher-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Codex Profile Switcher
SetupLogging=yes
CloseApplications=no
Uninstallable=yes

[Tasks]
Name: "desktopicon"; Description: "在桌面创建固定切换器入口"; GroupDescription: "快捷方式："

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\CodexProfileSwitcher.vbs"; DestDir: "{code:GetLauncherDirectory}"; DestName: "CodexProfileSwitcher.vbs"; Flags: onlyifdoesntexist uninsneveruninstall

[Icons]
Name: "{autoprograms}\Codex 账号切换"; Filename: "{sys}\wscript.exe"; Parameters: """{code:GetLauncherFile}"""; WorkingDir: "{code:GetLauncherDirectory}"
Name: "{autodesktop}\Codex 账号切换"; Filename: "{sys}\wscript.exe"; Parameters: """{code:GetLauncherFile}"""; WorkingDir: "{code:GetLauncherDirectory}"; Tasks: desktopicon
Name: "{autoprograms}\卸载 Codex 账号切换"; Filename: "{uninstallexe}"

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{code:GetLauncherFile}"""; Description: "启动 Codex 账号切换"; WorkingDir: "{code:GetLauncherDirectory}"; Flags: nowait postinstall skipifsilent unchecked

[Code]
function GetLauncherDirectory(Param: String): String;
begin
  Result := ExpandConstant('{param:SWITCHERLAUNCHERDIR|}');
  if Result = '' then
    Result := ExpandConstant('{localappdata}\CodexProfileSwitcher\Launcher');
end;

function GetLauncherFile(Param: String): String;
begin
  Result := AddBackslash(GetLauncherDirectory('')) + 'CodexProfileSwitcher.vbs';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  LauncherDirectory: String;
begin
  if CurStep = ssPostInstall then
  begin
    LauncherDirectory := GetLauncherDirectory('');
    ForceDirectories(LauncherDirectory);
    if not SaveStringToFile(AddBackslash(LauncherDirectory) + 'install-path.txt', ExpandConstant('{app}'), False) then
      RaiseException('无法保存切换器入口的安装路径。');
  end;
end;
