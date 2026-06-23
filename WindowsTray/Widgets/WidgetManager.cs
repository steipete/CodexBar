namespace CodexBarTray;

/// <summary>
/// Owns the live desktop widget windows: restores saved ones on launch, adds and
/// removes them on request, persists their positions, and pushes fresh data into
/// each on every refresh. All members must be called on the UI thread (they
/// create and mutate WPF windows).
/// </summary>
public sealed class WidgetManager
{
    private readonly WidgetStore _store;
    private readonly List<DesktopWidget> _widgets = new();
    private WidgetData _latest = WidgetData.Empty;

    /// <summary>Raised when a widget's "Refresh" is invoked; the app re-fetches.</summary>
    public event Action? RefreshRequested;

    public WidgetManager(WidgetStore store) => _store = store;

    public int Count => _widgets.Count;

    /// <summary>True when any live widget needs /cost data, so the app fetches it.</summary>
    public bool NeedsCost =>
        _widgets.Any(w => w.Vm is CostWidgetViewModel or CostHistoryWidgetViewModel);

    public void RestoreSaved()
    {
        foreach (var config in _store.Widgets.ToList())
            CreateWindow(config);
    }

    public DesktopWidget AddWidget(string providerId, WidgetKind kind, QuotaWindowKind window = QuotaWindowKind.Session)
    {
        var config = new WidgetConfig { ProviderId = providerId, Kind = kind, Window = window };
        _store.Widgets.Add(config);
        _store.Save();
        return CreateWindow(config);
    }

    public void RemoveWidget(DesktopWidget widget)
    {
        _widgets.Remove(widget);
        _store.Widgets.RemoveAll(c => c.Id == widget.WidgetId);
        _store.Save();
        widget.Close();
    }

    public void RemoveAll()
    {
        foreach (var widget in _widgets.ToList())
            RemoveWidget(widget);
    }

    /// <summary>Push the latest data into every open widget.</summary>
    public void UpdateData(WidgetData data)
    {
        _latest = data;
        foreach (var widget in _widgets)
            widget.Vm.Update(data);
    }

    /// <summary>Close all windows without forgetting them (used on app exit).</summary>
    public void CloseAll()
    {
        foreach (var widget in _widgets)
            widget.Close();
        _widgets.Clear();
    }

    private DesktopWidget CreateWindow(WidgetConfig config)
    {
        var content = CreateContent(config);
        content.Update(_latest);
        var widget = new DesktopWidget(config, content);
        widget.RemoveRequested += RemoveWidget;
        widget.RefreshRequested += () => RefreshRequested?.Invoke();
        widget.PositionChanged += OnPositionChanged;
        _widgets.Add(widget);
        widget.Show();
        return widget;
    }

    private static WidgetContentViewModel CreateContent(WidgetConfig config)
    {
        var name = UsageViewModelBuilder.DisplayName(config.ProviderId);
        return config.Kind switch
        {
            WidgetKind.Cost => new CostWidgetViewModel(config.ProviderId, name),
            WidgetKind.CostHistory => new CostHistoryWidgetViewModel(config.ProviderId, name),
            WidgetKind.BurnDown => new BurnDownWidgetViewModel(config.ProviderId, name, config.Window),
            _ => new UsageWidgetViewModel(config.ProviderId, name),
        };
    }

    private void OnPositionChanged(DesktopWidget widget)
    {
        var config = _store.Widgets.FirstOrDefault(c => c.Id == widget.WidgetId);
        if (config is null) return;
        config.Left = widget.Left;
        config.Top = widget.Top;
        _store.Save();
    }
}
