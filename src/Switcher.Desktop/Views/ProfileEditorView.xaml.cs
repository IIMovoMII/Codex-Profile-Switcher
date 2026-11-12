using System.Windows;
using System.Windows.Controls;
using Switcher.Desktop.ViewModels;
namespace Switcher.Desktop.Views;
public partial class ProfileEditorView : UserControl
{
    public ProfileEditorView() => InitializeComponent();
    private void KeyChanged(object sender, RoutedEventArgs e) { if (DataContext is ProfileEditorViewModel editor) editor.ApiKey = KeyInput.Password; }
    private void EditorChanged(object sender, DependencyPropertyChangedEventArgs e) { if (KeyInput is not null) KeyInput.Clear(); }
}
