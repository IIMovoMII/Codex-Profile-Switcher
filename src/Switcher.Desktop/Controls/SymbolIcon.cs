using System.Windows;
using System.Windows.Media;

namespace Switcher.Desktop.Controls;

/// <summary>Small vector symbols drawn at the current display scale.</summary>
public sealed class SymbolIcon : FrameworkElement
{
    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(nameof(Kind), typeof(string), typeof(SymbolIcon), new FrameworkPropertyMetadata("layers", FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty ForegroundProperty = DependencyProperty.Register(nameof(Foreground), typeof(Brush), typeof(SymbolIcon), new FrameworkPropertyMetadata(Brushes.Black, FrameworkPropertyMetadataOptions.AffectsRender));
    public string Kind { get => (string)GetValue(KindProperty); set => SetValue(KindProperty, value); }
    public Brush Foreground { get => (Brush)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }

    private static readonly IReadOnlyDictionary<string, Geometry> Symbols = new Dictionary<string, string>
    {
        ["user"] = "M16,7 A4,4 0 1 1 8,7 A4,4 0 1 1 16,7 M4,21 L4,18 C4,12 20,12 20,18 L20,21 Z",
        ["layers"] = "M12,2 L22,7 L12,12 L2,7 Z M2,12 L12,17 L22,12 M2,17 L12,22 L22,17",
        ["code"] = "M8,5 L2,12 L8,19 M16,5 L22,12 L16,19 M14,3 L10,21",
        ["wrench"] = "M14,3 C11,4 10,7 12,10 L3,19 A2,2 0 0 0 6,22 L15,13 C19,15 23,11 22,7 L18,10 L15,7 L18,3 Z",
        ["log"] = "M6,2 L18,2 Q20,2 20,4 L20,20 Q20,22 18,22 L6,22 Q4,22 4,20 L4,4 Q4,2 6,2 Z M8,7 L16,7 M8,11 L16,11 M8,15 L13,15",
        ["settings"] = "M10,2 L14,2 L15,5 L18,6 L21,6 L23,10 L20,12 L20,15 L21,18 L18,21 L15,20 L12,21 L9,23 L5,21 L5,18 L3,15 L1,14 L1,10 L4,9 L5,6 L5,3 Z M16,12 A4,4 0 1 1 8,12 A4,4 0 1 1 16,12",
        ["search"] = "M17,10 A7,7 0 1 1 3,10 A7,7 0 1 1 17,10 M15,15 L22,22",
        ["plus"] = "M12,4 L12,20 M4,12 L20,12",
        ["chevron"] = "M6,9 L12,15 L18,9",
        ["arrow"] = "M5,12 L19,12 M13,6 L19,12 L13,18",
        ["close"] = "M6,6 L18,18 M18,6 L6,18",
        ["check"] = "M5,12 L10,17 L20,6",
        ["success"] = "M22,12 A10,10 0 1 1 2,12 A10,10 0 1 1 22,12 M7,12 L11,16 L17,8",
        ["info"] = "M22,12 A10,10 0 1 1 2,12 A10,10 0 1 1 22,12 M12,10 L12,17 M12,6 L12,7",
        ["warning"] = "M12,2 L23,21 L1,21 Z M12,8 L12,14 M12,17 L12,18",
        ["refresh"] = "M21,9 A9,9 0 0 0 5,5 L2,8 M2,2 L2,8 L8,8 M3,15 A9,9 0 0 0 19,19 L22,16 M16,16 L22,16 L22,22",
        ["monitor"] = "M3,3 L21,3 Q22,3 22,5 L22,16 Q22,18 20,18 L4,18 Q2,18 2,16 L2,5 Q2,3 3,3 Z M12,18 L12,22 M7,22 L17,22",
        ["terminal"] = "M4,5 L10,11 L4,17 M12,19 L21,19",
        ["folder"] = "M2,6 L2,20 Q2,22 4,22 L20,22 Q22,22 22,20 L22,8 Q22,6 20,6 L11,6 L8,3 L4,3 Q2,3 2,6 Z",
        ["clock"] = "M22,12 A10,10 0 1 1 2,12 A10,10 0 1 1 22,12 M12,5 L12,12 L17,15",
        ["chat"] = "M22,11 C22,1 2,1 2,11 C2,15 4,17 7,18 L5,22 L12,19 C18,19 22,16 22,11 Z M7,11 L8,11 M11,11 L12,11 M15,11 L16,11",
        ["cube"] = "M12,2 L22,7 L22,18 L12,23 L2,18 L2,7 Z M2,7 L12,12 L22,7 M12,12 L12,23 M7,4 L17,9",
        ["download"] = "M12,2 L12,16 M6,10 L12,16 L18,10 M3,16 L3,22 L21,22 L21,16",
        ["external"] = "M14,2 L22,2 L22,10 M22,2 L11,13 M10,3 L4,3 Q2,3 2,5 L2,20 Q2,22 4,22 L19,22 Q21,22 21,20 L21,14",
        ["power"] = "M12,1 L12,12 M6,4 A10,10 0 1 0 18,4",
        ["eye"] = "M1,12 Q12,-2 23,12 Q12,26 1,12 Z M16,12 A4,4 0 1 1 8,12 A4,4 0 1 1 16,12",
    }.ToDictionary(pair => pair.Key, pair => Geometry.Parse(pair.Value));

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        var pen = new Pen(Foreground, 1.6) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        drawingContext.PushTransform(new ScaleTransform(ActualWidth / 24, ActualHeight / 24));
        drawingContext.DrawGeometry(null, pen, Symbols.GetValueOrDefault(Kind, Symbols["layers"]));
        drawingContext.Pop();
    }
}
