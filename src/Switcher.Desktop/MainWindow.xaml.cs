using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using Switcher.Infrastructure;
namespace Switcher.Desktop;
public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    public MainWindow(ApplicationHost host)
    {
        InitializeComponent(); DataContext = _viewModel = new MainViewModel(host);
        _viewModel.SelectFallbackLocations = resolution =>
        {
            var dialog = new Views.LocationRecoveryWindow(new Infrastructure.Configuration.DataLocationResolver(), resolution) { Owner = this };
            if (dialog.ShowDialog() == true)
            {
                _viewModel.LocationMessage = "已验证并记住新位置，请关闭并重新打开切换器后使用。现有窗口的路径保持不变。";
                _viewModel.HasUnavailableLocations = !new Infrastructure.Configuration.DataLocationResolver().Verify(host.Paths).IsValid;
            }
        };
    }
    private async void WindowLoaded(object sender, RoutedEventArgs e) => await _viewModel.InitializeAsync();
    private void DragTitle(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) MaximizeWindow(sender, e); else if (e.ChangedButton == MouseButton.Left) DragMove();
    }
    private void MinimizeWindow(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void MaximizeWindow(object sender, RoutedEventArgs e) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void CloseWindow(object sender, RoutedEventArgs e) => Close();
    private void DismissEditor(object sender, MouseButtonEventArgs e) => _viewModel.CloseEditorCommand.Execute(null);
    private void WindowKeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Escape && _viewModel.HasEditor) { _viewModel.CloseEditorCommand.Execute(null); e.Handled = true; } }
    private void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (_viewModel.IsBusy) { e.Cancel = true; MessageBox.Show(this, "操作正在进行，请先取消并等待安全收尾后再关闭。", "正在处理", MessageBoxButton.OK, MessageBoxImage.Information); return; }
        if (_viewModel.Editor?.HasChanges == true && !_viewModel.Confirm("放弃尚未保存的账号修改并关闭？", "关闭切换助手")) e.Cancel = true;
    }
}
