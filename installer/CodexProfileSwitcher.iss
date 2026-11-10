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
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Codex 账号切换"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start.vbs"""; WorkingDir: "{app}"
Name: "{autodesktop}\Codex 账号切换"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start.vbs"""; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{autoprograms}\卸载 Codex 账号切换"; Filename: "{uninstallexe}"

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\start.vbs"""; Description: "启动 Codex 账号切换"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent unchecked
