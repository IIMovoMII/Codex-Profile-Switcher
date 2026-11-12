using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
namespace Switcher.Desktop.Views;
public partial class AccountsView : UserControl
{
    public AccountsView() => InitializeComponent();
    private void ShowMenu(object sender, RoutedEventArgs e)
    {
        if (sender is Button { ContextMenu: { } menu } button)
        {
            menu.PlacementTarget = button;
            menu.Placement = PlacementMode.Custom;
            menu.CustomPopupPlacementCallback = (popup, target, _) => [new(new Point(target.Width - popup.Width, target.Height + 5), PopupPrimaryAxis.Vertical)];
            menu.IsOpen = true;
        }
    }
}
