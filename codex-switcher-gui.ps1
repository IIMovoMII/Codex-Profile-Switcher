#requires -Version 5.1
[CmdletBinding()]
param([string]$CodexHome,[string]$DataDir,[string]$CodexExecutable,[string]$MonitorDataDir,[switch]$UnsafeAllowRunningCodex,[switch]$NoShow)

$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
. (Join-Path $PSScriptRoot 'codex-profile-switcher.ps1') -LibraryOnly -CodexHome $CodexHome -DataDir $DataDir -CodexExecutable $CodexExecutable -MonitorDataDir $MonitorDataDir -UnsafeAllowRunningCodex:$UnsafeAllowRunningCodex
$script:AppRoot=$PSScriptRoot
$script:WorkerEngine=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Job=$null;$script:View=$null;$script:Filter='all';$script:SelectedPage='Accounts';$script:CancelRecovery=$false
$script:LastLogPath=Join-Path $DataDir 'last-gui-operation.json'
[xml]$xaml=[IO.File]::ReadAllText((Join-Path $script:AppRoot 'ui\MainWindow.xaml'))
$reader=New-Object Xml.XmlNodeReader($xaml)
$script:Window=[Windows.Markup.XamlReader]::Load($reader)
$script:UI=@{}
# FindName avoids depending on WPF-generated field names or code-behind.
foreach($name in @('NavAccounts','NavEnvironment','NavLogs','Breadcrumb','TopStatus','UpdateButton','RefreshButton','AccountsPage','EnvironmentPage','LogsPage','AddButton','ImportButton','ActiveName','ActiveDetail','FilterAll','FilterOfficial','FilterApi','SearchBox','ProfileList','EmptyPanel','EmptyAddButton','SharedSummary','HomePath','DiagnosticSummary','DiagnosticTitle','DiagnosticHint','DiagnosticList','DiagnosticDetails','PassedDiagnosticList','LogText','LogHeading','StatusText','CancelButton','StatusBar')) { $script:UI[$name]=$script:Window.FindName($name) }

function Set-UiStatus([string]$Text,[bool]$ErrorState=$false) {
    $script:UI.StatusText.Text=$Text
    $script:UI.StatusBar.Background=if($ErrorState){'#FFF1EC'}else{'#F5F6F8'}
}
function Show-UiError($Failure) {
    $message=if($Failure -is [Management.Automation.ErrorRecord]){$Failure.Exception.Message}else{[string]$Failure}
    Set-UiStatus $message $true
    [void][Windows.MessageBox]::Show($script:Window,$message,'操作未完成','OK','Warning')
}
function Select-UiPage([string]$Name) {
    $script:SelectedPage=$Name
    $labels=@{Accounts='账号与接口';Environment='环境检查';Logs='操作记录'}
    foreach($key in $labels.Keys) {
        $script:UI[$key+'Page'].Visibility=if($key -eq $Name){'Visible'}else{'Collapsed'}
        $script:UI['Nav'+$key].Background=if($key -eq $Name){'#E6E9ED'}else{'Transparent'}
    }
    $script:UI.Breadcrumb.Text='工作区  /  '+$labels[$Name]
    if($Name -eq 'Environment'){Render-Diagnostics}
}
function Fill-ProxyChoices($Combo,[string]$Value) {
    $Combo.Items.Clear()
    foreach($choice in @(@('保留现有配置','preserve'),@('跟随系统代理','system'),@('不跟随系统代理','direct'))) {
        [void]$Combo.Items.Add([pscustomobject]@{Label=$choice[0];Value=$choice[1]})
    }
    $Combo.DisplayMemberPath='Label'
    $Combo.SelectedIndex=0
    foreach($item in $Combo.Items){if($item.Value -eq $Value){$Combo.SelectedItem=$item;break}}
}
function New-ProxyHelpIndicator {
    $help=New-Object Windows.Controls.Border
    $help.Width=17;$help.Height=17;$help.CornerRadius='8.5';$help.BorderThickness='1';$help.BorderBrush='#B2BAC4';$help.Background='#F5F6F8';$help.Margin='7,0,0,0';$help.Cursor=[Windows.Input.Cursors]::Help;$help.Focusable=$true
    $mark=New-Object Windows.Controls.TextBlock;$mark.Text='?';$mark.FontSize=11;$mark.FontWeight='SemiBold';$mark.Foreground='#78828F';$mark.HorizontalAlignment='Center';$mark.VerticalAlignment='Center';$help.Child=$mark
    $explanation=@'
可以把系统代理理解成电脑上网时的一条“中转路线”。比如你打开了 Clash 之类的代理软件，并开启“系统代理”，Windows 就会把这条路线告诉愿意跟随它的软件。

跟随系统代理：让 Codex 使用 Windows 设置的这条路线。如果你平时得开代理才能访问官方服务，通常可以选它。

不跟随系统代理：让 Codex 不主动读取这条系统代理。如果你的 API 地址不用代理也能连上，可以考虑选它。不过，代理软件的 TUN 等接管方式不受这个选项控制，不能保证所有流量都直连。

保留现有配置：不改 Codex 现在的代理选项。不确定时，可以先选这个。

这里只保存这个账号的选择，不会替你打开代理软件，也不会修改 Windows 的代理地址或开关。保存后，下次切换或“重新应用”这个账号时生效。
'@
    $tip=New-Object Windows.Controls.ToolTip;$tip.Padding='15';$tip.Placement='Right';$tip.MaxWidth=390;$tip.Background='White';$tip.BorderBrush='#DDE2E8';$tip.BorderThickness='1'
    $body=New-Object Windows.Controls.StackPanel
    $title=New-Object Windows.Controls.TextBlock;$title.Text='系统代理是做什么的？';$title.FontSize=14;$title.FontWeight='SemiBold';$title.Foreground='#252B32'
    $text=New-Object Windows.Controls.TextBlock;$text.Text=$explanation;$text.TextWrapping='Wrap';$text.Width=350;$text.FontSize=12;$text.LineHeight=20;$text.Foreground='#57616E';$text.Margin='0,9,0,0'
    [void]$body.Children.Add($title);[void]$body.Children.Add($text);$tip.Content=$body;$help.ToolTip=$tip
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($help,180);[Windows.Controls.ToolTipService]::SetShowDuration($help,120000)
    [Windows.Automation.AutomationProperties]::SetName($help,'系统代理说明');[Windows.Automation.AutomationProperties]::SetHelpText($help,$explanation)
    return $help
}
function Render-Profiles {
    if($null -eq $script:View){return}
    $query=$script:UI.SearchBox.Text.Trim()
    $items=@()
    foreach($profile in @($script:View.Profiles)) {
        if($script:Filter -ne 'all' -and $script:Filter -ne $profile.Kind){continue}
        if($query -and ($profile.Name+' '+$profile.BaseUrl+' '+$profile.Identity).IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
        $subtitle=if($profile.Kind -eq 'api'){$profile.BaseUrl}elseif($profile.Identity){$profile.Identity}else{'ChatGPT 官方账号'}
        $model=if($profile.Model){$profile.Model}else{'保留当前模型'}
        $summary=if($profile.Kind -eq 'api'){'API 接口'}else{'官方 OAuth'}
        $summary+='   ·   '+$model+'   ·   '+$profile.Status
        $items += [pscustomobject]@{Id=$profile.Id;Kind=$profile.Kind;Name=$profile.Name;Subtitle=$subtitle;Summary=$summary;Active=$profile.Active;Icon=$(if($profile.Kind -eq 'api'){'{ }'}else{'O'});ActiveVisibility=$(if($profile.Active){'Visible'}else{'Collapsed'});SwitchLabel=$(if($profile.Active){'重新应用'}else{'切换'});Source=$profile}
    }
    $script:UI.ProfileList.ItemsSource=$items
    $script:UI.EmptyPanel.Visibility=if($items.Count -eq 0){'Visible'}else{'Collapsed'}
    foreach($pair in @(@('FilterAll','all'),@('FilterOfficial','official'),@('FilterApi','api'))){$script:UI[$pair[0]].Background=if($script:Filter -eq $pair[1]){'#ECEEF1'}else{'White'}}
}
function Refresh-UiState {
    try {
        $script:View=Get-SwitcherViewState
        $active=@($script:View.Profiles | Where-Object Active)
        $script:UI.ActiveName.Text=if($active.Count){$active[0].Name}elseif($script:View.Mode -eq 'official'){'当前官方账号（待导入）'}elseif($script:View.Mode -eq 'api'){'当前 API 接口（待导入）'}else{'从第一个账号开始'}
        $script:UI.ActiveDetail.Text=if($active.Count){if($active[0].Kind -eq 'api'){$active[0].BaseUrl}else{'ChatGPT 官方账号 · 本地数据持续保留'}}elseif($script:View.Issue){$script:View.Issue}else{'导入现有账号，或添加一个新的连接。'}
        $script:UI.ImportButton.Visibility=if($script:View.Initialized -and @($script:View.Profiles).Count -gt 0){'Collapsed'}else{'Visible'}
        $script:UI.SharedSummary.Text=[string]$script:View.ProjectCount+' 个本地项目 · 账号之间共用'
        $script:UI.HomePath.Text=$CodexHome;$script:UI.HomePath.ToolTip=$CodexHome
        Render-Profiles
        if($script:View.Issue){Set-UiStatus $script:View.Issue $true}
    } catch {Set-UiStatus $_.Exception.Message $true}
}
function Render-Diagnostics {
    $script:UI.DiagnosticList.Children.Clear()
    $script:UI.PassedDiagnosticList.Children.Clear()
    $script:UI.DiagnosticDetails.IsExpanded=$false
    $script:UI.DiagnosticDetails.Visibility='Collapsed'
    try {
        $checks=@(Get-SwitcherDiagnostics)
        $errors=@($checks | Where-Object Status -eq 'error')
        $reminders=@($checks | Where-Object Status -ne 'ok' | Where-Object Status -ne 'error')
        $passed=@($checks | Where-Object Status -eq 'ok')
        $problems=@($errors)+@($reminders)
        $script:UI.DiagnosticSummary.Background=if($errors.Count){'#FFF3EE'}elseif($reminders.Count){'#FAF7EF'}else{'#F3F7F5'}
        $script:UI.DiagnosticTitle.Text=if($errors.Count){'暂时无法切换'}elseif($reminders.Count){'切换前还有 '+$reminders.Count+' 项提醒'}else{'检查通过'}
        $script:UI.DiagnosticHint.Text=if($problems.Count){'处理下面的提示后，点击右上角刷新。'}else{'本地环境已就绪，可以切换账号。'}
        foreach($check in $problems) {
            $border=New-Object Windows.Controls.Border
            $border.BorderBrush='#E5E8EC';$border.BorderThickness='1';$border.CornerRadius='11';$border.Padding='18';$border.Margin='0,0,0,10'
            $border.Tag=$check.Name
            $stack=New-Object Windows.Controls.StackPanel
            $title=New-Object Windows.Controls.TextBlock;$title.FontWeight='SemiBold';$title.FontSize=14
            $title.Text=$(if($check.Status -eq 'error'){'!  '}else{'·  '})+$check.Name;$title.Foreground=if($check.Status -eq 'error'){'#B66D41'}else{'#687181'}
            $detail=New-Object Windows.Controls.TextBlock;$detail.Text=$check.Detail;$detail.TextWrapping='Wrap';$detail.FontSize=12;$detail.Foreground='#858B94';$detail.Margin='21,7,0,0'
            [void]$stack.Children.Add($title);[void]$stack.Children.Add($detail);$border.Child=$stack;[void]$script:UI.DiagnosticList.Children.Add($border)
        }
        foreach($check in $passed) {
            $row=New-Object Windows.Controls.DockPanel;$row.Margin='0,0,0,12'
            $status=New-Object Windows.Controls.TextBlock;$status.Text='正常';$status.Foreground='#458260';$status.FontSize=12;$status.Margin='16,0,0,0'
            [Windows.Controls.DockPanel]::SetDock($status,'Right');[void]$row.Children.Add($status)
            $name=New-Object Windows.Controls.TextBlock;$name.Text=$check.Name;$name.Foreground='#687181';$name.FontSize=12;[void]$row.Children.Add($name)
            [void]$script:UI.PassedDiagnosticList.Children.Add($row)
        }
        $script:UI.DiagnosticDetails.Header='检查明细（已通过 '+$passed.Count+' 项）'
        $script:UI.DiagnosticDetails.Visibility=if($passed.Count){'Visible'}else{'Collapsed'}
    }catch{
        $script:UI.DiagnosticTitle.Text='检查未完成';$script:UI.DiagnosticHint.Text=$_.Exception.Message;$script:UI.DiagnosticSummary.Background='#FFF3EE'
        Set-UiStatus $_.Exception.Message $true
    }
}
function ConvertTo-ProcessArgument([string]$Value) {
    # Windows CommandLineToArgvW quoting, passed directly to CreateProcess.
    return '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Start-UpdateWorker([string]$Mode,[string]$ResultPath,[string]$RequestPath) {
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:UpdaterPath,'-Mode',$Mode,'-ResultPath',$ResultPath)
    if($Mode -eq 'Check'){$arguments+=@('-CurrentVersion',$script:AppVersion)}else{$arguments+=@('-RequestPath',$RequestPath)}
    $line=($arguments | ForEach-Object {ConvertTo-ProcessArgument ([string]$_)}) -join ' '
    Start-Process -FilePath $script:WorkerEngine -ArgumentList $line -WindowStyle Hidden | Out-Null
}
function Start-UpdateCheck {
    if($NoShow){return}
    try{
        $updateDirectory=Join-Path $DataDir 'updates'
        [void][IO.Directory]::CreateDirectory($updateDirectory)
        $resultPath=Join-Path $updateDirectory ('check-'+[Guid]::NewGuid().ToString('N')+'.json')
        $script:UpdateTask=[pscustomobject]@{Mode='Check';ResultPath=$resultPath;RequestPath=$null;Started=[DateTime]::UtcNow}
        Start-UpdateWorker 'Check' $resultPath $null
        $script:UpdateTimer.Start()
    }catch{$script:UpdateTask=$null}
}
function Start-UpdateDownload {
    if($null -eq $script:AvailableUpdate){return}
    if($null -ne $script:Job){Show-UiError '请等待当前切换操作完成后再安装更新。';return}
    $answer=[Windows.MessageBox]::Show($script:Window,('发现新版本 v'+$script:AvailableUpdate.latest_version+'。现在下载并安装吗？安装程序启动后会关闭切换器。'),'Codex 账号切换更新','YesNo','Question')
    if($answer -ne 'Yes'){return}
    try{
        $updateDirectory=Join-Path $DataDir 'updates'
        [void][IO.Directory]::CreateDirectory($updateDirectory)
        $id=[Guid]::NewGuid().ToString('N')
        $requestPath=Join-Path $updateDirectory ('download-'+$id+'.json')
        $resultPath=Join-Path $updateDirectory ('download-'+$id+'.result.json')
        $request=[ordered]@{latest_version=$script:AvailableUpdate.latest_version;asset_name=$script:AvailableUpdate.asset_name;download_url=$script:AvailableUpdate.download_url;checksum_url=$script:AvailableUpdate.checksum_url}
        $encoding=New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($requestPath,(ConvertTo-Json -InputObject $request -Depth 5),$encoding)
        $script:UpdateTask=[pscustomobject]@{Mode='Download';ResultPath=$resultPath;RequestPath=$requestPath;Started=[DateTime]::UtcNow}
        $script:UI.UpdateButton.IsEnabled=$false
        Set-UiStatus '正在下载并校验更新安装包…'
        Start-UpdateWorker 'Download' $resultPath $requestPath
        $script:UpdateTimer.Start()
    }catch{
        $script:UpdateTask=$null;$script:UI.UpdateButton.IsEnabled=$true
        Show-UiError $_
    }
}
function Complete-UpdateTask {
    $task=$script:UpdateTask
    if($null -eq $task){$script:UpdateTimer.Stop();return}
    if(-not [IO.File]::Exists($task.ResultPath)){
        if(([DateTime]::UtcNow-$task.Started).TotalSeconds -gt 150){
            $script:UpdateTimer.Stop();$script:UpdateTask=$null
            if($task.Mode -eq 'Download'){
                $script:UI.UpdateButton.IsEnabled=$true
                Show-UiError '更新下载超时，请稍后重试。'
            }
        }
        return
    }
    $script:UpdateTimer.Stop()
    try{
        $result=Get-Content -Raw -LiteralPath $task.ResultPath | ConvertFrom-Json
        if([IO.File]::Exists($task.ResultPath)){[IO.File]::Delete($task.ResultPath)}
        if($task.RequestPath -and [IO.File]::Exists($task.RequestPath)){[IO.File]::Delete($task.RequestPath)}
        $script:UpdateTask=$null
        if($task.Mode -eq 'Check'){
            if($result.state -eq 'update'){
                $script:AvailableUpdate=$result
                $script:UI.UpdateButton.Content='更新至 v'+$result.latest_version
                $script:UI.UpdateButton.ToolTip='从 GitHub Releases 下载并安装经过 SHA-256 校验的更新'
                $script:UI.UpdateButton.Visibility='Visible'
                $script:UI.UpdateButton.IsEnabled=$null -eq $script:Job
            }
            return
        }
        if($result.state -ne 'ready' -or -not [IO.File]::Exists([string]$result.path)){
            $script:UI.UpdateButton.IsEnabled=$true
            throw [string]$result.message
        }
        if($null -ne $script:Job){
            $script:DownloadedInstaller=[string]$result.path
            $script:UI.UpdateButton.IsEnabled=$true
            Set-UiStatus '更新已下载，请等待当前操作完成后安装。'
            return
        }
        Start-Process -FilePath ([string]$result.path) | Out-Null
        $script:Window.Close()
    }catch{
        if($task.Mode -eq 'Download'){
            $script:UI.UpdateButton.IsEnabled=$true
            Show-UiError $_
        }
    }
}
function Start-UiOperation([System.Collections.IDictionary]$Request,[string]$Title) {
    if($null -ne $script:Job){Set-UiStatus '请等待当前操作完成。';return}
    try {
        $id=[Guid]::NewGuid().ToString('N');$requests=Join-Path $DataDir 'requests';$logs=Join-Path $DataDir 'operations'
        [void][IO.Directory]::CreateDirectory($requests);[void][IO.Directory]::CreateDirectory($logs)
        $requestPath=Join-Path $requests ($id+'.dpapi')
        $bytes=$script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $Request -Depth 12 -Compress))
        try{$encrypted=Protect-BytesForCurrentUser $bytes}finally{[Array]::Clear($bytes,0,$bytes.Length)}
        Write-AtomicBytes -Path $requestPath -Bytes $encrypted
        $output=Join-Path $logs ($id+'.log');$errorLog=Join-Path $logs ($id+'.error.log')
        $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $script:AppRoot 'codex-profile-switcher.ps1'),'-Command','request','-RequestPath',$requestPath,'-CodexHome',$CodexHome,'-DataDir',$DataDir)
        if($CodexExecutable){$arguments+=@('-CodexExecutable',$CodexExecutable)}
        if($script:MonitorMaintenanceEnabled){$arguments+=@('-MonitorDataDir',$MonitorDataDir)}
        if($UnsafeAllowRunningCodex){$arguments+='-UnsafeAllowRunningCodex'}
        $line=($arguments | ForEach-Object {ConvertTo-ProcessArgument ([string]$_)}) -join ' '
        $process=Start-Process -FilePath $script:WorkerEngine -ArgumentList $line -WindowStyle Hidden -RedirectStandardOutput $output -RedirectStandardError $errorLog -PassThru
        # Retain a process handle before a short-lived worker exits (Windows PowerShell 5.1).
        $null=$process.Handle
        $script:Job=[pscustomobject]@{Process=$process;Output=$output;ErrorLog=$errorLog;Title=$Title;RequestPath=$requestPath;Action=[string]$Request['action']}
        if($null -ne $script:AvailableUpdate){$script:UI.UpdateButton.IsEnabled=$false}
        $script:UI.TopStatus.Text='正在处理';$script:UI.CancelButton.Visibility='Visible';$script:UI.AddButton.IsEnabled=$false;$script:UI.ImportButton.IsEnabled=$false
        $script:UI.LogHeading.Text=$Title;$script:UI.LogText.Text='正在开始…'
        Select-UiPage 'Logs';Set-UiStatus ($Title+'…')
        $script:Timer.Start()
    }catch{Show-UiError $_}
}
function Read-UiOperationLog($Job) {
    $text=''
    foreach($path in @($Job.Output,$Job.ErrorLog)){
        if([IO.File]::Exists($path)){
            $stream=[IO.File]::Open($path,'Open','Read','ReadWrite')
            try{$reader=New-Object IO.StreamReader($stream,$script:Utf8NoBom,$true);$text+=$reader.ReadToEnd()+[Environment]::NewLine}finally{$stream.Dispose()}
        }
    }
    if($text.Length -gt 100000){$text=$text.Substring($text.Length-100000)}
    return $text.Trim()
}
function Complete-UiTick {
    if($null -eq $script:Job){$script:Timer.Stop();return}
    try{
        $job=$script:Job;$text=Read-UiOperationLog $job
        if($text){$script:UI.LogText.Text=$text;$script:UI.LogText.ScrollToEnd()}
        $job.Process.Refresh()
        if(-not $job.Process.HasExited){return}
        $job.Process.WaitForExit();$code=$job.Process.ExitCode
        if($null -eq $code){$code=1}
        $record=[ordered]@{title=$job.Title;output=$job.Output;error=$job.ErrorLog;exit_code=$code;utc=[DateTime]::UtcNow.ToString('o')}
        Write-AtomicText $script:LastLogPath (ConvertTo-Json -InputObject $record)
        if([IO.File]::Exists($job.RequestPath)){[IO.File]::Delete($job.RequestPath)}
        $job.Process.Dispose();$script:Job=$null;$script:Timer.Stop()
        $script:UI.TopStatus.Text='本地运行';$script:UI.CancelButton.Visibility='Collapsed';$script:UI.AddButton.IsEnabled=$true;$script:UI.ImportButton.IsEnabled=$true
        if($null -ne $script:AvailableUpdate){$script:UI.UpdateButton.IsEnabled=$true}
        Refresh-UiState
        if($script:CancelRecovery){$script:CancelRecovery=$false;Start-UiOperation @{action='recover'} '恢复取消前的状态';return}
        Set-UiStatus $(if($code -eq 0){$job.Title+'已完成，结果保留在操作记录中。'}else{'操作未完成，请查看上方记录；可在账号菜单中更新凭据或重新登录。'}) ($code -ne 0)
    }catch{Set-UiStatus $_.Exception.Message $true}
}
function Show-ProfileEditor([AllowNull()]$Profile,[switch]$NoDisplay) {
    if($null -ne $script:Job){return}
    $editing=$null -ne $Profile
    $dialog=New-Object Windows.Window
    if($script:Window.IsVisible){$dialog.Owner=$script:Window}
    $dialog.WindowStartupLocation='CenterOwner';$dialog.Title=if($editing){'编辑名称与配置'}else{'添加账号'}
    $dialog.Width=560;$dialog.Height=735;$dialog.MinHeight=600;$dialog.ResizeMode='CanResize';$dialog.Background='White';$dialog.FontFamily=$script:Window.FontFamily;$dialog.FontSize=13
    $outer=New-Object Windows.Controls.Grid;$outer.Margin='28'
    foreach($height in @('Auto','*','Auto')){$row=New-Object Windows.Controls.RowDefinition;$row.Height=$height;[void]$outer.RowDefinitions.Add($row)}
    $head=New-Object Windows.Controls.StackPanel
    $heading=New-Object Windows.Controls.TextBlock;$heading.Text=$dialog.Title;$heading.FontSize=24;$heading.FontWeight='SemiBold';[void]$head.Children.Add($heading)
    $description=New-Object Windows.Controls.TextBlock;$description.Text='设置只对这个账号生效，保存后在切换或重新应用时使用。';$description.Foreground='#7D838D';$description.Margin='0,9,0,23';$description.TextWrapping='Wrap';[void]$head.Children.Add($description);[void]$outer.Children.Add($head)
    $scroll=New-Object Windows.Controls.ScrollViewer;$scroll.VerticalScrollBarVisibility='Auto';[Windows.Controls.Grid]::SetRow($scroll,1)
    $form=New-Object Windows.Controls.StackPanel;$form.Margin='0,0,9,0';$scroll.Content=$form;[void]$outer.Children.Add($scroll)
    $fields=@{}
    foreach($spec in @(@('kind','连接类型'),@('name','账号名称'),@('base_url','API 地址（HTTPS）'),@('api_key',$(if($editing){'API Key（留空保留原密钥）'}else{'API Key'})),@('model','模型名称（可选）'),@('context_window','上下文窗口（可选）'),@('proxy_policy','系统代理'),@('model_catalog_json','模型目录 JSON 路径（可选）'))) {
        $stack=New-Object Windows.Controls.StackPanel;$stack.Margin='0,0,0,16'
        $labelRow=New-Object Windows.Controls.StackPanel;$labelRow.Orientation='Horizontal';$labelRow.Margin='0,0,0,8'
        $label=New-Object Windows.Controls.TextBlock;$label.Text=$spec[1];$label.Foreground='#525B66';[void]$labelRow.Children.Add($label)
        if($spec[0] -eq 'proxy_policy'){$help=New-ProxyHelpIndicator;[void]$labelRow.Children.Add($help);$fields['proxy_help']=$help}
        [void]$stack.Children.Add($labelRow)
        if($spec[0] -in @('kind','proxy_policy')){$control=New-Object Windows.Controls.ComboBox;$control.MinHeight=39;$control.Padding='9,7'}elseif($spec[0] -eq 'api_key'){$control=New-Object Windows.Controls.PasswordBox;$control.Padding='10,10';$control.BorderBrush='#DDE1E7'}else{$control=New-Object Windows.Controls.TextBox;$control.Padding='10,10';$control.BorderBrush='#DDE1E7'}
        $control.Tag=$spec[0];[Windows.Automation.AutomationProperties]::SetName($control,$spec[1]);[void]$stack.Children.Add($control);[void]$form.Children.Add($stack)
        if($spec[0] -eq 'context_window'){
            $hint=New-Object Windows.Controls.TextBlock;$hint.Text='单位为 token。留空保留 Codex 当前值，没有配置时跟随模型默认。';$hint.TextWrapping='Wrap';$hint.FontSize=11;$hint.Foreground='#858B94';$hint.Margin='0,7,0,0';[void]$stack.Children.Add($hint)
        }
        $fields[$spec[0]]=$control;$fields[$spec[0]+'_row']=$stack
    }
    [void]$fields.kind.Items.Add('官方 ChatGPT 账号');[void]$fields.kind.Items.Add('自定义 API 接口');$fields.kind.SelectedIndex=0
    Fill-ProxyChoices $fields.proxy_policy 'preserve'
    if($editing){
        $fields.kind.SelectedIndex=if($Profile.Kind -eq 'api'){1}else{0};$fields.kind.IsEnabled=$false
        $fields.name.Text=$Profile.Name;$fields.base_url.Text=$Profile.BaseUrl;$fields.model.Text=$Profile.Model;$fields.context_window.Text=$Profile.ContextWindow;$fields.model_catalog_json.Text=$Profile.Catalog
        Fill-ProxyChoices $fields.proxy_policy $Profile.ProxyPolicy
    }
    $foot=New-Object Windows.Controls.StackPanel;[Windows.Controls.Grid]::SetRow($foot,2)
    $errorText=New-Object Windows.Controls.TextBlock;$errorText.Foreground='#BE6745';$errorText.TextWrapping='Wrap';$errorText.Margin='0,12,0,9';[void]$foot.Children.Add($errorText)
    $buttonRow=New-Object Windows.Controls.StackPanel;$buttonRow.Orientation='Horizontal';$buttonRow.HorizontalAlignment='Right'
    $cancel=New-Object Windows.Controls.Button;$cancel.Content='取消';$cancel.Padding='22,10';$cancel.Margin='0,0,9,0'
    $save=New-Object Windows.Controls.Button;$save.Content=if($editing){'保存配置'}else{'添加账号'};$save.Padding='22,10';$save.Background='#23272C';$save.Foreground='White';$save.BorderBrush='#23272C'
    [void]$buttonRow.Children.Add($cancel);[void]$buttonRow.Children.Add($save);[void]$foot.Children.Add($buttonRow);[void]$outer.Children.Add($foot)
    # GetNewClosure creates a dynamic module that cannot see functions in
    # this script when launched through start-gui.ps1. Keep callbacks bound
    # to this script and store per-dialog data on the controls instead.
    $editorContext=@{Dialog=$dialog;Fields=$fields;Editing=$editing;Profile=$Profile;Description=$description;Error=$errorText}
    $fields.kind.Tag=$editorContext;$cancel.Tag=$editorContext;$save.Tag=$editorContext
    $updateKind={
        param($sender,$event)
        $context=$sender.Tag;$fields=$context.Fields
        $isApi=$fields.kind.SelectedIndex -eq 1
        foreach($key in @('base_url','api_key','model_catalog_json')){$fields[$key+'_row'].Visibility=if($isApi){'Visible'}else{'Collapsed'}}
        if(-not $context.Editing){$context.Description.Text=if($isApi){'保存这个 API 的连接信息，之后可随时切换。凭据仅保存在此电脑。'}else{'将在浏览器中登录。请确认登录的是你要添加的账号。'}}
    }
    $fields.kind.Add_SelectionChanged($updateKind);& $updateKind $fields.kind $null
    $cancel.Add_Click({param($sender,$event)$sender.Tag.Dialog.Close()})
    $save.Add_Click({
        param($sender,$event)
        $context=$sender.Tag;$fields=$context.Fields;$editing=$context.Editing
        try{
            $kind=if($fields.kind.SelectedIndex -eq 1){'api'}else{'official'}
            $name=$fields.name.Text.Trim();if(-not $name){throw '请输入账号名称。'}
            Assert-ContextWindow $fields.context_window.Text
            $request=[ordered]@{action=$(if($editing){'edit'}elseif($kind -eq 'api'){'add-api'}else{'add-official'});kind=$kind;name=$name;model=$fields.model.Text.Trim();context_window=$fields.context_window.Text.Trim();proxy_policy=[string]$fields.proxy_policy.SelectedItem.Value;settings_scope='account'}
            if($editing){$request['selector']=$context.Profile.Id}
            if($kind -eq 'api'){
                Assert-RelayBaseUrl $fields.base_url.Text.Trim()
                if(-not $editing -and $fields.api_key.Password.Length -eq 0){throw '请输入 API Key。'}
                $request['base_url']=$fields.base_url.Text.Trim();$request['api_key']=$fields.api_key.Password;$request['model_catalog_json']=$fields.model_catalog_json.Text.Trim()
                if($request['model_catalog_json'] -and -not [IO.File]::Exists($request['model_catalog_json'])){throw '模型目录文件不存在。'}
            }
            $context.Dialog.Close();Start-UiOperation $request $(if($editing){'保存账号配置'}else{'添加账号'})
            $fields.api_key.Clear();$request.Remove('api_key')
        }catch{$context.Error.Text=$_.Exception.Message}
    })
    $dialog.Content=$outer
    if($NoDisplay){return [pscustomobject]@{Window=$dialog;Fields=$fields;Save=$save;Error=$errorText}}
    [void]$dialog.ShowDialog()
}
function Show-ProfileActions($Button,$Item) {
    $menu=New-Object Windows.Controls.ContextMenu
    $Button.ContextMenu=$menu
    $edit=New-Object Windows.Controls.MenuItem;$edit.Header='编辑名称与配置';$edit.Tag=$Item
    $edit.Add_Click({param($sender,$event)try{Show-ProfileEditor $sender.Tag.Source}catch{Show-UiError $_}});[void]$menu.Items.Add($edit)
    if($Item.Kind -eq 'official'){
        $reauth=New-Object Windows.Controls.MenuItem;$reauth.Header='重新登录此账号';$reauth.Tag=$Item
        $reauth.Add_Click({param($sender,$event)try{Start-UiOperation @{action='reauthorize';selector=$sender.Tag.Id} '重新登录账号'}catch{Show-UiError $_}});[void]$menu.Items.Add($reauth)
    }
    [void]$menu.Items.Add((New-Object Windows.Controls.Separator))
    $remove=New-Object Windows.Controls.MenuItem;$remove.Header='移除本地档案';$remove.IsEnabled=-not $Item.Active;$remove.Tag=$Item
    $remove.Add_Click({
        param($sender,$event)
        try{
            $item=$sender.Tag
            $answer=[Windows.MessageBox]::Show($script:Window,('移除“'+$item.Name+'”的本地登录档案？聊天与项目会继续保留。'),'移除账号','YesNo','Question')
            if($answer -eq 'Yes'){Start-UiOperation @{action='remove';kind=$item.Kind;selector=$item.Id} '移除账号档案'}
        }catch{Show-UiError $_}
    });[void]$menu.Items.Add($remove);$menu.PlacementTarget=$Button;$menu.IsOpen=$true
}

$script:Timer=New-Object Windows.Threading.DispatcherTimer;$script:Timer.Interval=[TimeSpan]::FromMilliseconds(350);$script:Timer.Add_Tick({Complete-UiTick})
$script:UpdaterPath=Join-Path $script:AppRoot 'codex-updates.ps1'
$script:AppVersion=(Get-Content -Raw -LiteralPath (Join-Path $script:AppRoot 'version.txt')).Trim()
$script:UpdateTask=$null;$script:AvailableUpdate=$null;$script:DownloadedInstaller=$null
$script:UpdateTimer=New-Object Windows.Threading.DispatcherTimer;$script:UpdateTimer.Interval=[TimeSpan]::FromMilliseconds(400);$script:UpdateTimer.Add_Tick({Complete-UpdateTask})
$script:UI.UpdateButton.Add_Click({
    if($script:DownloadedInstaller){
        if($script:Job){Show-UiError '请等待当前切换操作完成后再安装更新。';return}
        Start-Process -FilePath $script:DownloadedInstaller | Out-Null
        $script:Window.Close()
    }else{Start-UpdateDownload}
})
$script:UI.NavAccounts.Add_Click({Select-UiPage 'Accounts'});$script:UI.NavEnvironment.Add_Click({Select-UiPage 'Environment'});$script:UI.NavLogs.Add_Click({Select-UiPage 'Logs'})
$script:UI.RefreshButton.Add_Click({if($script:Job){return};Refresh-UiState;if($script:SelectedPage -eq 'Environment'){Render-Diagnostics}})
$script:UI.FilterAll.Add_Click({$script:Filter='all';Render-Profiles});$script:UI.FilterOfficial.Add_Click({$script:Filter='official';Render-Profiles});$script:UI.FilterApi.Add_Click({$script:Filter='api';Render-Profiles});$script:UI.SearchBox.Add_TextChanged({Render-Profiles})
$script:UI.AddButton.Add_Click({Show-ProfileEditor $null});$script:UI.EmptyAddButton.Add_Click({Show-ProfileEditor $null})
$script:UI.ImportButton.Add_Click({if([IO.File]::Exists($ConfigPath) -and [IO.File]::Exists($AuthPath)){Start-UiOperation @{action='initialize'} '导入当前账号'}else{Show-ProfileEditor $null}})
$script:UI.ProfileList.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{param($sender,$event)
    try{$button=$event.OriginalSource;while($button -and $button -isnot [Windows.Controls.Button]){$button=[Windows.Media.VisualTreeHelper]::GetParent($button)};if(-not $button){return};$item=$button.DataContext
        if($button.Tag -eq 'switch'){Start-UiOperation @{action='use';kind=$item.Kind;selector=$item.Id} ('切换到 '+$item.Name)}elseif($button.Tag -eq 'menu'){Show-ProfileActions $button $item}
    }catch{Show-UiError $_}
})
$script:UI.CancelButton.Add_Click({
    if(-not $script:Job){return}
    try{$script:CancelRecovery=$script:Job.Action -ne 'recover';$kill=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') -ArgumentList @('/PID',[string]$script:Job.Process.Id,'/T','/F') -WindowStyle Hidden -Wait -PassThru;$kill.Dispose();Set-UiStatus '正在取消并恢复操作前的状态…'}catch{Show-UiError $_}
})
$script:Window.Add_Closing({param($sender,$event)if($script:Job){$event.Cancel=$true;Set-UiStatus '操作尚未结束。可以点击“取消操作”，完成恢复后再关闭。'}})
Refresh-UiState
Start-UpdateCheck
if([IO.File]::Exists($script:LastLogPath)){
    try{$record=Read-DesktopJson (Read-TextFile $script:LastLogPath);$script:UI.LogHeading.Text=[string]$record.title;$script:UI.LogText.Text=Read-UiOperationLog ([pscustomobject]@{Output=$record.output;ErrorLog=$record.error})}catch{}
}
if(-not $NoShow){[void]$script:Window.ShowDialog()}
