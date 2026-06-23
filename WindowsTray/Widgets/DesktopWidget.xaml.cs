using System.Windows;
using System.Windows.Input;

namespace CodexBarTray;

/// <summary>
/// A single borderless, always-on-top desktop widget. Shared chrome (header,
/// drag, ×, context menu); the body is chosen per content type via implicit
/// DataTemplates. Position and removal are reported back to the
/// <see cref="WidgetManager"/> via events. Data is pushed in by the manager on
/// each refresh through the bound <see cref="WidgetContentViewModel"/>.
/// </summary>
public partial class DesktopWidget : Window
{
    public string WidgetId { get; }
    public WidgetContentViewModel Vm { get; }

    /// <summary>Raised when the user removes this widget (× or context menu).</summary>
    public event Action<DesktopWidget>? RemoveRequested;

    /// <summary>Raised when the user asks this widget to refresh.</summary>
    public event Action? RefreshRequested;

    /// <summary>Raised after a drag, with the new (Left, Top).</summary>
    public event Action<DesktopWidget>? PositionChanged;

    public DesktopWidget(WidgetConfig config, WidgetContentViewModel content)
    {
        InitializeComponent();
        WidgetId = config.Id;
        Vm = content;
        DataContext = content;
        Loaded += (_, _) => PositionWindow(config);
    }

    private void PositionWindow(WidgetConfig config)
    {
        UpdateLayout();
        if (config.Left is double left && config.Top is double top)
        {
            Left = Clamp(left,
                SystemParameters.VirtualScreenLeft,
                SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - ActualWidth);
            Top = Clamp(top,
                SystemParameters.VirtualScreenTop,
                SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - ActualHeight);
        }
        else
        {
            // First placement: cascade down the right edge of the work area.
            var work = SystemParameters.WorkArea;
            Left = work.Right - ActualWidth - 12;
            Top = work.Top + 12;
        }
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);

        // Pressing the × removes the widget rather than starting a drag.
        if (ReferenceEquals(e.OriginalSource, CloseButton))
        {
            e.Handled = true;
            RemoveRequested?.Invoke(this);
            return;
        }

        if (e.ButtonState != MouseButtonState.Pressed) return;

        try { DragMove(); }
        catch { /* DragMove throws if the button was released mid-call */ }

        PositionChanged?.Invoke(this);
    }

    private void OnRefreshClick(object sender, RoutedEventArgs e) => RefreshRequested?.Invoke();

    private void OnRemoveClick(object sender, RoutedEventArgs e) => RemoveRequested?.Invoke(this);

    private static double Clamp(double value, double min, double max)
        => max < min ? min : Math.Min(Math.Max(value, min), max);
}
