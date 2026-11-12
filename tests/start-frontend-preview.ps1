#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$DotNetPath, [switch]$AutomaticLocations, [string]$EvidenceDirectory)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$previewRoot = Join-Path ([IO.Path]::GetTempPath()) ('SwitcherFrontendPreview-' + [Guid]::NewGuid().ToString('N'))
$previewHome = Join-Path $previewRoot 'codex home 中文'
$previewData = Join-Path $previewRoot 'switcher data 中文'
if ($AutomaticLocations) { $previewData = Join-Path $previewRoot 'local\CodexProfileSwitcher' }
$previewMock = Join-Path $previewRoot 'mock'
foreach ($directory in @($previewHome, $previewData, $previewMock)) { [void][IO.Directory]::CreateDirectory($directory) }
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $previewMock 'MockCodex.csproj'), '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup></Project>', $utf8)
[IO.File]::WriteAllText((Join-Path $previewMock 'Program.cs'), 'await Task.Delay(1800); Console.Error.WriteLine("synthetic diagnostic notice"); Console.WriteLine("Logged in using an API key"); return 0;', $utf8)
& $DotNetPath build (Join-Path $previewMock 'MockCodex.csproj') --output (Join-Path $previewMock 'bin') --verbosity quiet
if ($LASTEXITCODE -ne 0) { throw 'Mock CLI build failed.' }
$cliDll = Join-Path $project 'src\Switcher.Cli\bin\Debug\net10.0-windows\Switcher.Cli.dll'
$desktopDll = Join-Path $project 'src\Switcher.Desktop\bin\Debug\net10.0-windows\CodexProfileSwitcher.dll'
if (-not [IO.File]::Exists($desktopDll)) { throw 'Run dotnet build first.' }
$catalog = Join-Path $previewData 'relay-models.json'
[IO.File]::WriteAllText($catalog, '{"models":[{"slug":"custom-model-a","display_name":"示例模型 A","context_window":128000,"unknown":{"nullable":null,"single":[1]}},{"slug":"custom-model-b","display_name":"示例模型 B"}]}', $utf8)
foreach ($entry in @(@('工作接口', 'https://api.example.com/v1', 'synthetic-api-one'), @('开发接口', 'https://dev.example.com/v1', 'synthetic-api-two'))) {
    $entry[2] | & $DotNetPath $cliDll profile-add-api --codex-home $previewHome --data-dir $previewData --name $entry[0] --base-url $entry[1] --catalog $catalog
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic API fixture creation failed.' }
}
foreach ($suffix in @('primary', 'backup')) {
    $claims = @{ email = ('preview-' + $suffix + '@example.invalid'); 'https://api.openai.com/auth' = @{ chatgpt_account_id = ('preview-' + $suffix); chatgpt_user_id = ('user-' + $suffix); chatgpt_plan_type = 'plus' } } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $auth = @{ auth_mode = 'chatgpt'; tokens = @{ id_token = ('test.' + $payload + '.signature'); account_id = ('preview-' + $suffix); access_token = 'synthetic-access'; refresh_token = 'synthetic-refresh' } } | ConvertTo-Json -Depth 5 -Compress
    $authPath = Join-Path $previewRoot ($suffix + '-synthetic-auth.json')
    [IO.File]::WriteAllText($authPath, $auth, $utf8)
    $name = if ($suffix -eq 'primary') { '个人账号' } else { '备用账号' }
    & $DotNetPath $cliDll profile-add-official --codex-home $previewHome --data-dir $previewData --name $name --auth-file $authPath
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic official fixture creation failed.' }
    if ($suffix -eq 'primary') { [IO.File]::WriteAllText((Join-Path $previewHome 'auth.json'), $auth, $utf8) }
}
[IO.File]::WriteAllText((Join-Path $previewHome 'config.toml'), "# synthetic preview only`r`nmodel_provider = `"openai`"`r`nmodel = `"keep-user-model`"`r`n", $utf8)
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = [IO.Path]::GetFullPath($DotNetPath)
$mockExe = Join-Path $previewMock 'bin\MockCodex.exe'
$start.Arguments = '"' + $desktopDll + '" --codex-home "' + $previewHome + '" --data-dir "' + $previewData + '" --codex-exe "' + $mockExe + '"'
if ($AutomaticLocations) {
    $start.Arguments = '"' + $desktopDll + '" --codex-exe "' + $mockExe + '"'
    $start.EnvironmentVariables['USERPROFILE'] = Join-Path $previewRoot 'user'
    $start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $previewRoot 'local'
    $start.EnvironmentVariables['CODEX_HOME'] = $previewHome
    [void][IO.Directory]::CreateDirectory((Join-Path $previewRoot 'user\Desktop'))
}
$start.EnvironmentVariables['APPDATA'] = Join-Path $previewRoot 'roaming'
$start.UseShellExecute = $false
$start.EnvironmentVariables['CODEX_SWITCHER_DISABLE_UPDATE_CHECK'] = '1'
$start.EnvironmentVariables['DOTNET_ROOT'] = Split-Path -Parent $DotNetPath
foreach ($variable in @('OPENAI_API_KEY', 'OPENAI_BASE_URL', 'CODEX_ACCESS_TOKEN')) { $start.EnvironmentVariables.Remove($variable) }
$previewProcess = [Diagnostics.Process]::Start($start)
if (-not $EvidenceDirectory) { $EvidenceDirectory = Join-Path $project ('artifacts\ui-' + [IO.File]::ReadAllText((Join-Path $project 'version.txt')).Trim()) }
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$evidence = @{ root = $previewRoot; home = $previewHome; data = $previewData; mock = $mockExe; pid = $previewProcess.Id }
[IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'fixture.json'), ($evidence | ConvertTo-Json), $utf8)
Write-Output ('Isolated preview: ' + $previewRoot)
