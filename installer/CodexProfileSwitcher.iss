#define AppName "Codex 账号切换"
#define AppVersion GetEnv("CODEX_SWITCHER_VERSION")
#define AppPublisher "Codex Profile Switcher contributors"
#define AppId "{{9D9E1F65-39F2-4CC4-9B3D-67AD77A54D7D}}"
#define SourceDir GetEnv("CODEX_SWITCHER_SOURCE")
#define OutputDir GetEnv("CODEX_SWITCHER_OUTPUT")

[Setup]
AppId={code:GetApplicationId}
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
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
WizardStyle=modern
UninstallDisplayName=Codex 账号切换
SetupLogging=yes
CloseApplications=no
Uninstallable=yes
ShowLanguageDialog=no
UsePreviousLanguage=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"

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
const
  LegacyLauncherSha256 = 'c76301c7fa887265fbc97dd3fca0dbf5efa6c15d95ecb6583d6b25c297b09413';
  PreviousDotNetLauncherSha256 = '5c3d1fdf6ad3c61eb348cd5af6747f43e8f13a6e604b2575d060e9b315cb8339';

function GetApplicationId(Param: String): String;
var
  TestId: String;
  Index: Integer;
begin
  TestId := ExpandConstant('{param:SWITCHERTESTID|}');
  if TestId = '' then begin
    Result := ExpandConstant('{#AppId}');
    Exit;
  end;
  if Length(TestId) <> 32 then
    RaiseException('Invalid isolated installation identifier.');
  for Index := 1 to Length(TestId) do
    if Pos(TestId[Index], '0123456789abcdef') = 0 then
      RaiseException('Invalid isolated installation identifier.');
  Result := 'CPS-Test-' + TestId;
end;

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

function GetLegacyPowerShellHash(const RelativePath: String): String;
begin
  Result := '';
  if CompareText(RelativePath, 'codex-desktop-state.ps1') = 0 then Result := 'e480d54d2c76dda48cf9a10578791f0eb8b712374d7f26aecb7cfb1cbf067b7b'
  else if CompareText(RelativePath, 'codex-history-compat.ps1') = 0 then Result := '545cd830c1ab050494673e753ad7f80a0fefc73782d572ae3b4cf9bb67977011'
  else if CompareText(RelativePath, 'codex-history-incremental.ps1') = 0 then Result := '8cc6f01162d373ecc246ba6661783573ffb5a5b14461302b401efe73fa350d9a'
  else if CompareText(RelativePath, 'codex-profile-registry.ps1') = 0 then Result := 'e659add276448ce444ce24feef1abd4b17c5fa782abb647143faa8c3073bea41'
  else if CompareText(RelativePath, 'codex-profile-switcher.ps1') = 0 then Result := '60671831f6a43e2e79d20392f16b3974ebc2b00b94e8cc96a2cf6bd244473185'
  else if CompareText(RelativePath, 'codex-project-projection.ps1') = 0 then Result := '4165bfa2b82a71b21278ac1daa52d82ee673a0da9d23bdf3d924476bde7b8056'
  else if CompareText(RelativePath, 'codex-switcher-gui.ps1') = 0 then Result := 'ea39e46564ccd5fa08f140bb175c7746d797b76c105d966b4bd2b3bad04988b4'
  else if CompareText(RelativePath, 'codex-switcher-service.ps1') = 0 then Result := 'f78bd929a8162fed16add5dbf2b6e026dc2381efdfdb9f8e4ce7eab5151d14e8'
  else if CompareText(RelativePath, 'codex-updates.ps1') = 0 then Result := '5aaf12b7f571c2cb0f3234cd4f84098892b8c28323865983a9e7452eb6eba0fc'
  else if CompareText(RelativePath, 'start-gui.ps1') = 0 then Result := '50b01af705699897335d8298adbe0cd0dd0f96dd2a770a2272b061d70655d046'
  else if CompareText(RelativePath, 'tools\sqlite3.ps1') = 0 then Result := '5272f44ff8cfdf459d55dcff82e08a815253f2ddb7fdc89932a28c60b0dbc39a';
end;

function IsSafeToolsDirectory: Boolean;
var
  FindRec: TFindRec;
begin
  Result := False;
  if FindFirst(AddBackslash(ExpandConstant('{app}')) + '*', FindRec) then
  begin
    try
      repeat
        if CompareText(FindRec.Name, 'tools') = 0 then
        begin
          Result := ((FindRec.Attributes and $10) <> 0) and ((FindRec.Attributes and $400) = 0);
          Break;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function CollectPowerShellFiles(const Directory: String; var FileList: String): Boolean;
var
  FindRec: TFindRec;
  EntryPath: String;
  Extension: String;
begin
  Result := False;
  if FindFirst(AddBackslash(Directory) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          EntryPath := AddBackslash(Directory) + FindRec.Name;
          if (FindRec.Attributes and $10) <> 0 then
          begin
            if (FindRec.Attributes and $400) <> 0 then
            begin
              if FileList <> '' then FileList := FileList + #13#10;
              FileList := FileList + EntryPath + ' (junction/reparse point skipped)';
              Result := True;
            end
            else if CollectPowerShellFiles(EntryPath, FileList) then Result := True;
          end
          else
          begin
            Extension := Lowercase(ExtractFileExt(FindRec.Name));
            if (Extension = '.ps1') or (Extension = '.psm1') or (Extension = '.psd1') then
            begin
              if FileList <> '' then FileList := FileList + #13#10;
              FileList := FileList + EntryPath;
              Result := True;
            end;
          end;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

procedure MigrateLegacyPowerShellFiles(const LauncherDirectory: String);
var
  RelativePaths: TArrayOfString;
  I: Integer;
  RelativePath: String;
  TargetPath: String;
  ExpectedHash: String;
  RemainingFiles: String;
  WarningFile: String;
  MessageText: String;
begin
  SetArrayLength(RelativePaths, 11);
  RelativePaths[0] := 'codex-desktop-state.ps1';
  RelativePaths[1] := 'codex-history-compat.ps1';
  RelativePaths[2] := 'codex-history-incremental.ps1';
  RelativePaths[3] := 'codex-profile-registry.ps1';
  RelativePaths[4] := 'codex-profile-switcher.ps1';
  RelativePaths[5] := 'codex-project-projection.ps1';
  RelativePaths[6] := 'codex-switcher-gui.ps1';
  RelativePaths[7] := 'codex-switcher-service.ps1';
  RelativePaths[8] := 'codex-updates.ps1';
  RelativePaths[9] := 'start-gui.ps1';
  RelativePaths[10] := 'tools\sqlite3.ps1';

  for I := 0 to GetArrayLength(RelativePaths) - 1 do
  begin
    RelativePath := RelativePaths[I];
    TargetPath := AddBackslash(ExpandConstant('{app}')) + RelativePath;
    ExpectedHash := GetLegacyPowerShellHash(RelativePath);
    if ((RelativePath <> 'tools\sqlite3.ps1') or IsSafeToolsDirectory) and
       FileExists(TargetPath) and (ExpectedHash <> '') then
      if CompareText(GetSHA256OfFile(TargetPath), ExpectedHash) = 0 then
        DeleteFile(TargetPath);
  end;

  RemainingFiles := '';
  if CollectPowerShellFiles(ExpandConstant('{app}'), RemainingFiles) then
  begin
    MessageText := '安装目录中还有内容已修改或不属于已知旧版的 PowerShell 文件，安装器已保留这些文件：' + #13#10 +
      RemainingFiles + #13#10#13#10 + '如需清理，请先确认这些文件不含自定义内容。';
    WarningFile := AddBackslash(LauncherDirectory) + 'legacy-powershell-migration-warning.txt';
    SaveStringToFile(WarningFile, MessageText + #13#10, False);
    if not WizardSilent then SuppressibleMsgBox(MessageText, mbInformation, MB_OK, IDOK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  LauncherDirectory: String;
  LauncherFile: String;
  LauncherBackup: String;
  LauncherHash: String;
  SourceHash: String;
  WarningFile: String;
  MessageText: String;
  InstallPaths: TArrayOfString;
begin
  if CurStep = ssPostInstall then
  begin
    LauncherDirectory := GetLauncherDirectory('');
    ForceDirectories(LauncherDirectory);
    LauncherFile := GetLauncherFile('');
    if not FileExists(LauncherFile) then
    begin
      if not CopyFile(ExpandConstant('{app}\CodexProfileSwitcher.vbs'), LauncherFile, False) then
        RaiseException('无法创建固定切换器入口。');
    end
    else
    begin
      LauncherHash := GetSHA256OfFile(LauncherFile);
      if (CompareText(LauncherHash, LegacyLauncherSha256) = 0) or
         (CompareText(LauncherHash, PreviousDotNetLauncherSha256) = 0) then
      begin
        if CompareText(LauncherHash, LegacyLauncherSha256) = 0 then
          LauncherBackup := LauncherFile + '.legacy-0.2.9.bak'
        else
          LauncherBackup := LauncherFile + '.legacy-0.3.6.bak';
        if FileExists(LauncherBackup) then
        begin
          SourceHash := GetSHA256OfFile(LauncherBackup);
          if CompareText(SourceHash, LauncherHash) <> 0 then
            RaiseException('旧固定入口的备份路径已有其他内容；为避免覆盖，更新已停止。');
        end
        else if not CopyFile(LauncherFile, LauncherBackup, False) then
          RaiseException('无法备份旧固定入口；为避免覆盖，更新已停止。');
        if not CopyFile(ExpandConstant('{app}\CodexProfileSwitcher.vbs'), LauncherFile, False) then
          RaiseException('旧固定入口已备份，但新入口写入失败。');
      end
      else
      begin
        SourceHash := GetSHA256OfFile(ExpandConstant('{app}\CodexProfileSwitcher.vbs'));
        if CompareText(LauncherHash, SourceHash) <> 0 then
        begin
          MessageText := '检测到固定入口内容与旧版和当前版本均不同，安装器保留了原文件。' + #13#10 +
            '请检查文件：' + LauncherFile + #13#10 + '必要时手动将其更新为新版 .NET 启动器。';
          WarningFile := AddBackslash(LauncherDirectory) + 'launcher-migration-warning.txt';
          SaveStringToFile(WarningFile, MessageText + #13#10, False);
          if not WizardSilent then SuppressibleMsgBox(MessageText, mbInformation, MB_OK, IDOK);
        end;
      end;
    end;

    MigrateLegacyPowerShellFiles(LauncherDirectory);

    SetArrayLength(InstallPaths, 1);
    InstallPaths[0] := ExpandConstant('{app}');
    if not SaveStringsToUTF8File(AddBackslash(LauncherDirectory) + 'install-path.txt', InstallPaths, False) then
      RaiseException('无法保存切换器入口的安装路径。');
  end;
end;
