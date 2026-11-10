#requires -Version 5.1
[CmdletBinding()]
param([string]$AppDirectory)
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

$ErrorActionPreference='Stop'
if(-not $AppDirectory){$AppDirectory=$script:ProjectRoot}
$callbackTestSource=$script:ProjectRoot
$callbackTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('codex-callback-test-'+[Guid]::NewGuid().ToString('N'))
$global:CodexCallbackTest=@{Failure=$null;Visited=0;Breakpoints=@();MainTimer=$null;EditorTimer=$null;Editor=$null;Completed=$false;Step=0;Waiting=$false;Deadline=[DateTime]::UtcNow.AddSeconds(45)}
function Find-CallbackButton($Root,[string]$ProfileId){
    $queue=New-Object Collections.Queue;$queue.Enqueue($Root)
    while($queue.Count){
        $node=$queue.Dequeue()
        if($node -is [Windows.Controls.Button] -and $node.Tag -eq 'menu' -and $node.DataContext.Id -ceq $ProfileId){return $node}
        for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node);$i++){$queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($node,$i))}
    }
    throw 'Could not find the rendered profile menu button.'
}
try{
    $fixture=& (Join-Path $PSScriptRoot 'test-gui-fixture.ps1') -Root $callbackTestRoot
    $global:CodexCallbackTest.Home=$fixture.CodexHome;$global:CodexCallbackTest.Store=$fixture.DataDir
    $global:CodexCallbackTest.ExpectedConfig=(Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'config.toml')).Hash
    $global:CodexCallbackTest.ExpectedAuth=(Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'auth.json')).Hash
    $gui=Join-Path $AppDirectory 'codex-switcher-gui.ps1'
    $lines=[IO.File]::ReadAllLines($gui);$readyLine=0;$editorLine=0
    for($i=0;$i -lt $lines.Length;$i++){
        if($lines[$i] -match '^if\(-not \$NoShow\)'){$readyLine=$i+1}
        if($lines[$i] -match '^    if\(\$NoDisplay\)'){$editorLine=$i+1}
    }
    if(-not $readyLine -or -not $editorLine){throw 'Could not locate GUI readiness/editor boundaries.'}
    # Breakpoints only capture this app's controls and schedule its events.
    # Tests run after the action returns, inside the real modal event loop.
    $editorBreakpoint=Set-PSBreakpoint -Script $gui -Line $editorLine -Action {
        $global:CodexCallbackTest.Editor=@{Dialog=$dialog;Fields=$fields;Save=$save;Cancel=$cancel;Error=$errorText}
        $dialog.ShowInTaskbar=$false;$dialog.ShowActivated=$false;$dialog.Left=-2000;$dialog.Top=-2000;$dialog.WindowStartupLocation='Manual'
        $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(80)
        $timer.Add_Tick({
            param($sender,$event)
            $sender.Stop();$state=$global:CodexCallbackTest;$editor=$state.Editor
            try{
                if($state.Step -eq 3){
                    $editor.Cancel.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                }else{
                    $editor.Fields.name.Text='scope edited '+$state.Step
                    if($state.Step -eq 2){
                        $editor.Fields.kind.SelectedIndex=1
                        if($editor.Fields.base_url_row.Visibility -ne 'Visible'){throw 'Changing the connection type did not update the form.'}
                        $editor.Fields.base_url.Text='https://callback.example.com/v1';$editor.Fields.api_key.Password='scope-test-only-key'
                    }
                    $editor.Save.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                    if($editor.Error.Text){throw $editor.Error.Text}
                }
                $state.Visited++
            }catch{$state.Failure=$_.Exception.Message}
            finally{$editor.Dialog.Close()}
        })
        $global:CodexCallbackTest.EditorTimer=$timer;$timer.Start()
    }
    $global:CodexCallbackTest.Breakpoints+=$editorBreakpoint
    $readyBreakpoint=Set-PSBreakpoint -Script $gui -Line $readyLine -Action {
        $state=$global:CodexCallbackTest;$state.Window=$script:Window;$state.UI=$script:UI
        $script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false;$script:Window.Left=-2000;$script:Window.Top=-2000;$script:Window.WindowStartupLocation='Manual'
        $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(100)
        $timer.Add_Tick({
            param($sender,$event)
            $state=$global:CodexCallbackTest
            try{
                if($state.Failure){throw $state.Failure}
                if([DateTime]::UtcNow -gt $state.Deadline){throw 'The callback smoke test timed out.'}
                if($state.Waiting){
                    if($state.UI.TopStatus.Text -eq '正在处理'){return}
                    if($state.Step -lt 3){
                        $result=[IO.File]::ReadAllText((Join-Path $state.Store 'last-gui-operation.json'))|ConvertFrom-Json
                        if($result.exit_code -ne 0){throw ('The edit/add worker failed: '+$state.UI.LogText.Text)}
                        $registry=[IO.File]::ReadAllText((Join-Path $state.Store 'profiles.json'))|ConvertFrom-Json
                        $profiles=@($registry.api_profiles)+@($registry.official_profiles)
                        if(@($profiles|Where-Object name -eq ('scope edited '+$state.Step)).Count -ne 1){throw 'The selected profile was not saved.'}
                    }
                    $state.Waiting=$false;$state.Step++
                }
                if($state.Step -ge 4){
                    if($state.Visited -ne 4){throw 'A callback did not open or complete its dialog.'}
                    if((Get-FileHash -LiteralPath (Join-Path $state.Home 'config.toml')).Hash -cne $state.ExpectedConfig -or (Get-FileHash -LiteralPath (Join-Path $state.Home 'auth.json')).Hash -cne $state.ExpectedAuth){throw 'Editing profiles changed the live config/auth.'}
                    $state.Completed=$true;$sender.Stop();$state.Window.Close();return
                }
                $sender.Stop();$state.Waiting=$true
                if($state.Step -lt 2){
                    $kind=if($state.Step -eq 0){'api'}else{'official'}
                    $item=@($state.UI.ProfileList.ItemsSource | Where-Object Kind -eq $kind)[0]
                    $button=Find-CallbackButton $state.UI.ProfileList $item.Id
                    $button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                    $menu=$button.ContextMenu
                    if($null -eq $menu){throw 'The rendered account menu was not attached to its button.'}
                    $menu.IsOpen=$false
                    $menu.Items[0].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.MenuItem]::ClickEvent)))
                }else{$state.UI.AddButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))}
                $sender.Start()
            }catch{
                $state.Failure=$_.Exception.Message;$sender.Stop()
                if($state.EditorTimer){$state.EditorTimer.Stop()}
                if($state.Editor){$state.Editor.Dialog.Close()}
                $state.Window.Close()
            }
        })
        $state.MainTimer=$timer;$timer.Start()
    }
    $global:CodexCallbackTest.Breakpoints+=$readyBreakpoint
    # Use the normal child-script entry and ShowDialog. Dot-sourcing the GUI
    # into the test, or testing only -NoShow, misses callback scope failures.
    & (Join-Path $AppDirectory 'start-gui.ps1') -CodexHome $fixture.CodexHome -DataDir $fixture.DataDir -CodexExecutable $fixture.FakeCodex -MonitorDataDir (Join-Path $callbackTestRoot 'monitor')
    if($global:CodexCallbackTest.Failure){throw $global:CodexCallbackTest.Failure}
    if(-not $global:CodexCallbackTest.Completed){throw 'The callback test did not execute.'}
    Write-Output 'GUI callback scope test passed: normal startup/modal loop, rendered API/official card menus, edit/save, add/type selector, cancel, encrypted workers, live config/auth unchanged.'
}finally{
    foreach($breakpoint in $global:CodexCallbackTest.Breakpoints){Remove-PSBreakpoint -Breakpoint $breakpoint -ErrorAction SilentlyContinue}
    if($global:CodexCallbackTest.MainTimer){$global:CodexCallbackTest.MainTimer.Stop()}
    if($global:CodexCallbackTest.EditorTimer){$global:CodexCallbackTest.EditorTimer.Stop()}
    Remove-Variable -Name CodexCallbackTest -Scope Global -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($callbackTestRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-callback-test-*'){throw 'Unsafe callback test cleanup path.'}
    if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
