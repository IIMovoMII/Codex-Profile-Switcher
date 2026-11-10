#requires -Version 5.1
[CmdletBinding()]
param([string]$Artifacts)
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

$ErrorActionPreference='Stop'
if(-not $Artifacts){$Artifacts=Join-Path $script:ProjectRoot 'test-results\gui'}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('codex-gui-test-'+[Guid]::NewGuid().ToString('N'))
$testSource=$script:ProjectRoot
function Assert-Gui([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Wait-GuiOperation {
    $deadline=[DateTime]::UtcNow.AddSeconds(55)
    while($script:Job -and [DateTime]::UtcNow -lt $deadline){
        [void][Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 35
    }
    Assert-Gui ($null -eq $script:Job) 'The graphical worker did not finish.'
    $result=Read-DesktopJson (Read-TextFile $script:LastLogPath)
    Assert-Gui ($result.exit_code -eq 0) ('Graphical operation failed: '+$script:UI.LogText.Text)
}
function Export-Gui([string]$Name,$Visual=$script:Window.Content,[int]$Width=1180,[int]$Height=780){
    [void][IO.Directory]::CreateDirectory($Artifacts)
    $Visual.Measure((New-Object Windows.Size($Width,$Height)))
    $Visual.Arrange((New-Object Windows.Rect(0,0,$Width,$Height)))
    $Visual.UpdateLayout()
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($Width,$Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $background=New-Object Windows.Media.DrawingVisual;$drawing=$background.RenderOpen()
    $drawing.DrawRectangle([Windows.Media.Brushes]::White,$null,(New-Object Windows.Rect(0,0,$Width,$Height)));$drawing.Close();$bitmap.Render($background)
    $bitmap.Render($Visual)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $Artifacts ($Name+'.png')))
    try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
try{
    $fixture=& (Join-Path $PSScriptRoot 'test-gui-fixture.ps1') -Root $testRoot
    . (Join-Path $testSource 'codex-switcher-gui.ps1') -NoShow -CodexHome $fixture.CodexHome -DataDir $fixture.DataDir -CodexExecutable $fixture.FakeCodex -MonitorDataDir (Join-Path $testRoot 'monitor') -UnsafeAllowRunningCodex
    Assert-Gui ($null -eq $script:Window.FindName('NavSettings') -and $null -eq $script:Window.FindName('SettingsPage')) 'The separate settings page was not removed.'
    Write-AtomicText $script:SettingsPath '{"version":1,"official_proxy":"system","api_proxy":"direct","context_window":"8192"}'
    Refresh-UiState
    Assert-Gui (@($script:UI.ProfileList.ItemsSource).Count -eq 3) 'The account list did not load.'
    $script:UI.HomePath.Text='%USERPROFILE%\.codex';$script:UI.HomePath.ToolTip='%USERPROFILE%\.codex'
    Export-Gui 'accounts'
    $script:UI.FilterApi.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-Gui (@($script:UI.ProfileList.ItemsSource).Count -eq 2) 'The API filter did not update.'
    $script:UI.SearchBox.Text='备用'
    Assert-Gui (@($script:UI.ProfileList.ItemsSource).Count -eq 1) 'Searching profile names did not work.'
    $script:UI.SearchBox.Text='';$script:UI.FilterAll.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    $beforeConfig=[Convert]::ToBase64String([IO.File]::ReadAllBytes($ConfigPath))
    $beforeAuth=[Convert]::ToBase64String([IO.File]::ReadAllBytes($AuthPath))
    $editor=Show-ProfileEditor $null -NoDisplay
    $editor.Fields.kind.SelectedIndex=1
    $editor.Fields.name.Text='图形界面 API';$editor.Fields.base_url.Text='https://gui.example.com/v1';$editor.Fields.api_key.Password='gui-fixture-key'
    $editor.Fields.model.Text='gui-model';$editor.Fields.context_window.Text='4096';$editor.Fields.proxy_policy.SelectedItem=@($editor.Fields.proxy_policy.Items|Where-Object Value -eq 'system')[0]
    $editor.Save.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-Gui ([string]::IsNullOrWhiteSpace($editor.Error.Text)) ('The account editor failed: '+$editor.Error.Text)
    Wait-GuiOperation
    Assert-Gui ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ConfigPath)) -ceq $beforeConfig) 'Adding an API changed the live config.'
    Assert-Gui ([Convert]::ToBase64String([IO.File]::ReadAllBytes($AuthPath)) -ceq $beforeAuth) 'Adding an API changed the live authentication.'
    $created=@($script:View.Profiles | Where-Object Name -eq '图形界面 API')[0]
    Start-UiOperation @{action='use';kind='api';selector=$created.Id} '界面测试切换'
    Wait-GuiOperation
    $config=Read-TextFile $ConfigPath
    Assert-Gui ($config -match 'model = "gui-model"' -and $config -match 'model_context_window = 4096' -and $config -match 'respect_system_proxy = true') 'Per-profile model, context or proxy settings were not applied.'
    $live=@($script:View.Profiles | Where-Object Active)[0]
    $editor=Show-ProfileEditor $live -NoDisplay
    $editor.Fields.name.Text='更新后的 API';$editor.Fields.api_key.Password='gui-fixture-rotated-key';$editor.Fields.base_url.Text='https://new-gui.example.com/v1'
    $editor.Save.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-Gui ([string]::IsNullOrWhiteSpace($editor.Error.Text)) $editor.Error.Text
    Wait-GuiOperation
    Start-UiOperation @{action='use';kind='api';selector=$live.Id} '应用更新后的密钥'
    Wait-GuiOperation
    $auth=Read-DesktopJson (Read-AuthText)
    Assert-Gui ($auth.OPENAI_API_KEY -ceq 'gui-fixture-rotated-key') 'Reapplying an updated API profile restored the old key.'
    Assert-Gui (@($script:View.Profiles).Count -eq 4) 'Editing the active API created a duplicate old profile.'
    Assert-Gui ((Read-TextFile $ConfigPath) -match 'new-gui.example.com') 'Updating the API address did not take effect.'
    $live=@($script:View.Profiles|Where-Object Active)[0]
    $editor=Show-ProfileEditor $live -NoDisplay
    Assert-Gui ($editor.Fields.proxy_help.ToolTip -is [Windows.Controls.ToolTip]) 'The proxy hover explanation was not attached to the help circle.'
    $editor.Fields.context_window.Text='8192';$editor.Fields.proxy_policy.SelectedItem=@($editor.Fields.proxy_policy.Items|Where-Object Value -eq 'direct')[0]
    Export-Gui 'account-settings' $editor.Window.Content 560 700
    $editor.Window.Content.Children[1].ScrollToEnd();$editor.Window.Content.UpdateLayout()
    Export-Gui 'account-settings-details' $editor.Window.Content 560 700
    $tipBody=$editor.Fields.proxy_help.ToolTip.Content
    $tipBody.Measure((New-Object Windows.Size(350,[double]::PositiveInfinity)))
    Export-Gui 'proxy-help' $tipBody 350 ([int][Math]::Ceiling($tipBody.DesiredSize.Height))
    $editor.Save.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Wait-GuiOperation
    $saved=Find-ProfileEntry (Read-ProfileRegistry) api $live.Id
    Assert-Gui ($saved.context_window -eq '8192' -and $saved.proxy_policy -eq 'direct' -and $saved.settings_scope -eq 'account') 'Settings were not saved independently on the account.'
    Start-UiOperation @{action='use';kind='api';selector=$live.Id} '应用合并后的账号配置'
    Wait-GuiOperation
    Assert-Gui ((Read-TextFile $ConfigPath) -match 'model_context_window = 8192' -and (Read-TextFile $ConfigPath) -match 'respect_system_proxy = false') 'The merged settings did not apply on switching.'
    $backup=@($script:View.Profiles | Where-Object Name -eq '备用接口')[0]
    Start-UiOperation @{action='remove';kind='api';selector=$backup.Id} '测试移除闲置档案'
    Wait-GuiOperation
    Assert-Gui (@($script:View.Profiles).Count -eq 3) 'The inactive profile was not removed.'
    $script:UI.NavEnvironment.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-Gui ($script:UI.DiagnosticTitle.Text -ceq '检查通过' -and $script:UI.DiagnosticList.Children.Count -eq 0 -and
        $script:UI.PassedDiagnosticList.Children.Count -ge 7 -and -not $script:UI.DiagnosticDetails.IsExpanded) ('Healthy checks did not stay collapsed: '+$script:UI.StatusText.Text)
    Export-Gui 'environment'
    $previousApiOverride=[Environment]::GetEnvironmentVariable('OPENAI_API_KEY','Process')
    try {
        [Environment]::SetEnvironmentVariable('OPENAI_API_KEY','gui-environment-fixture-secret','Process')
        Render-Diagnostics
        Assert-Gui ($script:UI.DiagnosticTitle.Text -ceq '暂时无法切换' -and $script:UI.DiagnosticList.Children.Count -eq 1 -and
            $script:UI.DiagnosticList.Children[0].Tag -ceq '认证环境变量' -and -not $script:UI.DiagnosticDetails.IsExpanded) 'A blocking environment issue was hidden in the collapsed details.'
        Assert-Gui ($script:UI.DiagnosticList.Children[0].Child.Children[1].Text -notmatch 'gui-environment-fixture-secret') 'An environment-variable value was exposed in diagnostics.'
        Export-Gui 'environment-issue'
    } finally { [Environment]::SetEnvironmentVariable('OPENAI_API_KEY',$previousApiOverride,'Process') }
    Write-TransactionJournal -SourceMode api -TargetMode api -TargetConfigText (Read-TextFile $ConfigPath) -TargetAuthText (Read-AuthText)
    try {
        Render-Diagnostics
        Assert-Gui ($script:UI.DiagnosticList.Children.Count -eq 1 -and $script:UI.DiagnosticList.Children[0].Tag -ceq '上次操作恢复' -and
            $script:UI.DiagnosticTitle.Text -match '提醒') 'An unfinished-operation reminder was hidden.'
        Export-Gui 'environment-reminder'
    } finally { Complete-Transaction; Render-Diagnostics }
    $requests=Join-Path $DataDir 'requests'
    Assert-Gui (@(Get-ChildItem -LiteralPath $requests -File).Count -eq 0) 'A consumed encrypted request was left behind.'
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'operations') -File)){
        Assert-Gui ((Read-TextFile $file.FullName) -notmatch 'gui-fixture-(rotated-)?key') 'A graphical operation leaked the test API key.'
    }
    $script:Window.Close()
    $freshHome=Join-Path $testRoot 'first-use-home';$freshStore=Join-Path $testRoot 'first-use-store'
    . (Join-Path $testSource 'codex-switcher-gui.ps1') -NoShow -CodexHome $freshHome -DataDir $freshStore -CodexExecutable $fixture.FakeCodex -MonitorDataDir (Join-Path $testRoot 'monitor') -UnsafeAllowRunningCodex
    Assert-Gui (@($script:UI.ProfileList.ItemsSource).Count -eq 0 -and $script:UI.EmptyPanel.Visibility -eq 'Visible') 'The empty first-use page did not load.'
    Export-Gui 'first-use'
    $editor=Show-ProfileEditor $null -NoDisplay
    $editor.Fields.kind.SelectedIndex=1;$editor.Fields.name.Text='首次 API';$editor.Fields.base_url.Text='https://first-gui.example.com/v1';$editor.Fields.api_key.Password='first-gui-fixture-key'
    $editor.Fields.model.Text='first-model';$editor.Fields.context_window.Text='16384';$editor.Fields.proxy_policy.SelectedItem=@($editor.Fields.proxy_policy.Items|Where-Object Value -eq 'direct')[0]
    $editor.Save.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-Gui ([string]::IsNullOrWhiteSpace($editor.Error.Text)) $editor.Error.Text
    Wait-GuiOperation
    Assert-Gui (@($script:View.Profiles).Count -eq 1 -and $script:View.Initialized -and (Read-TextFile $ConfigPath) -match 'model_context_window = 16384' -and (Read-TextFile $ConfigPath) -match 'model = "first-model"' -and (Read-TextFile $ConfigPath) -match 'respect_system_proxy = false') 'First-use graphical setup did not apply its chosen connection and options.'
    $slowCli=Join-Path $testRoot 'slow-login.ps1'
    Write-AtomicText $slowCli @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
if($Arguments.Count -eq 1 -and $Arguments[0] -eq 'login'){
  [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'login-waiting'),'ready')
  Start-Sleep -Seconds 45
  exit 23
}
exit 3
'@
    $CodexExecutable=$slowCli
    $configBeforeCancel=(Get-FileHash -LiteralPath $ConfigPath).Hash;$authBeforeCancel=(Get-FileHash -LiteralPath $AuthPath).Hash
    Start-UiOperation @{action='add-official';kind='official';name='取消中的账号'} '测试取消登录'
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while(-not [IO.File]::Exists((Join-Path $CodexHome 'login-waiting')) -and [DateTime]::UtcNow -lt $deadline){
        [void][Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 35
    }
    Assert-Gui ([IO.File]::Exists((Join-Path $CodexHome 'login-waiting')) -and [IO.File]::Exists($TransactionPath)) 'The cancellation fixture did not reach its temporary-login transaction.'
    $script:UI.CancelButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Wait-GuiOperation
    Assert-Gui ((Get-FileHash -LiteralPath $ConfigPath).Hash -ceq $configBeforeCancel -and (Get-FileHash -LiteralPath $AuthPath).Hash -ceq $authBeforeCancel -and -not [IO.File]::Exists($TransactionPath) -and @($script:View.Profiles).Count -eq 1) 'Cancel did not recover the original account and configuration.'
    Write-Host 'GUI tests passed: WPF rendering, first-use setup, navigation/search, editor events, encrypted worker requests, add/edit/use/remove, active-key rotation, model/context/proxy overrides, persistent logs, cancel/transaction recovery.'
}finally{
    if($script:Window){$script:Window.Close()}
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'codex-gui-test-*'){
        if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
    }else{throw 'Unsafe GUI test cleanup path.'}
}
