using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Hardcodet.Wpf.TaskbarNotification;

namespace CodexBarTray;

public partial class App : Application
{
    private TaskbarIcon? _trayIcon;
    private ServeProcess? _serve;
    private UsageClient? _client;
    private DispatcherTimer? _refreshTimer;
    private MenuItem? _statusItem;

    private readonly UsageViewModel _usageVm = new();
    private readonly ConfigService _config = new();
    private readonly UiSettings _ui = UiSettings.Load();
    private readonly QuotaNotificationCoordinator _notifications = new();
    private readonly WidgetManager _widgets = new(WidgetStore.Load());
    private SettingsWindow? _settingsWindow;
    private UsageWindow? _usageWindow;
    private List<ProviderViewModel> _latestTiles = new();
    private bool _refreshing;

    private void OnStartup(object sender, StartupEventArgs e)
    {
        var popup = new UsagePopup { DataContext = _usageVm };
        _usageWindow = new UsageWindow(popup, _ui);

        _trayIcon = new TaskbarIcon
        {
            IconSource = TrayIconFactory.CreateDefault(),
            ToolTipText = "CodexBar — starting…",
            ContextMenu = BuildContextMenu(),
        };
        // Left-click toggles our own draggable window; refresh as it opens.
        _trayIcon.TrayLeftMouseUp += (_, _) =>
        {
            if (_usageWindow is null) return;
            var willShow = !_usageWindow.IsVisible;
            _usageWindow.ToggleFromTray();
            if (willShow && _usageWindow.IsVisible) _ = RefreshUsageAsync();
        };

        // Restore a pinned panel so it's there as soon as the app launches.
        if (_ui.AlwaysOnScreen) _usageWindow.ShowPanel();

        // Restore any pinned desktop widgets; they show "waiting for data" until
        // the first refresh, then update alongside the panel.
        _widgets.RefreshRequested += () => _ = RefreshUsageAsync();
        _widgets.RestoreSaved();

        _ = StartEngineAsync();
    }

    private ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();

        _statusItem = new MenuItem { Header = "Starting…", IsEnabled = false };
        menu.Items.Add(_statusItem);
        menu.Items.Add(new Separator());

        var refresh = new MenuItem { Header = "Refresh" };
        refresh.Click += async (_, _) => await RefreshUsageAsync();
        menu.Items.Add(refresh);

        var settings = new MenuItem { Header = "Settings…" };
        settings.Click += (_, _) => OpenSettings();
        menu.Items.Add(settings);

        var widgets = new MenuItem { Header = "Widgets" };
        // Rebuild the provider list each time so it reflects the latest refresh.
        widgets.SubmenuOpened += (_, _) => PopulateWidgetsMenu(widgets);
        widgets.Items.Add(new MenuItem { Header = "Loading…", IsEnabled = false });
        menu.Items.Add(widgets);

        var alwaysOnScreen = new MenuItem
        {
            Header = "Always on screen",
            IsCheckable = true,
            IsChecked = _ui.AlwaysOnScreen,
        };
        alwaysOnScreen.Click += (_, _) =>
        {
            if (_usageWindow is null) return;
            _usageWindow.AlwaysOnScreen = alwaysOnScreen.IsChecked;
            // Pinning brings the panel up (and keeps it up); unpinning leaves it
            // visible but it will now dismiss on click-away like a normal popover.
            if (alwaysOnScreen.IsChecked)
            {
                _usageWindow.ShowPanel();
                _ = RefreshUsageAsync();
            }
        };
        menu.Items.Add(alwaysOnScreen);

        var startup = new MenuItem { Header = "Start with Windows", IsCheckable = true };
        try { startup.IsChecked = StartupRegistration.IsEnabled(); } catch { /* registry unavailable */ }
        startup.Click += (_, _) =>
        {
            try { StartupRegistration.SetEnabled(startup.IsChecked); }
            catch { startup.IsChecked = !startup.IsChecked; }
        };
        menu.Items.Add(startup);

        menu.Items.Add(new Separator());

        var quit = new MenuItem { Header = "Quit CodexBar" };
        quit.Click += (_, _) => Shutdown();
        menu.Items.Add(quit);

        return menu;
    }

    // Cost data is only available for Claude and Codex (local token-cost files).
    private static readonly HashSet<string> CostProviderIds =
        new(StringComparer.OrdinalIgnoreCase) { "claude", "codex" };

    private void PopulateWidgetsMenu(MenuItem root)
    {
        root.Items.Clear();

        root.Items.Add(BuildAddSubmenu("Add usage widget", WidgetKind.Usage, _ => true));
        root.Items.Add(BuildAddSubmenu("Add cost widget", WidgetKind.Cost, CostProviderIds.Contains));
        root.Items.Add(BuildAddSubmenu("Add cost history", WidgetKind.CostHistory, CostProviderIds.Contains));
        root.Items.Add(BuildAddSubmenu("Add burn-down (session)", WidgetKind.BurnDown, _ => true, QuotaWindowKind.Session));
        root.Items.Add(BuildAddSubmenu("Add burn-down (weekly)", WidgetKind.BurnDown, _ => true, QuotaWindowKind.Weekly));

        root.Items.Add(new Separator());
        var removeAll = new MenuItem { Header = "Remove all widgets", IsEnabled = _widgets.Count > 0 };
        removeAll.Click += (_, _) => _widgets.RemoveAll();
        root.Items.Add(removeAll);
    }

    private MenuItem BuildAddSubmenu(
        string header,
        WidgetKind kind,
        Func<string, bool> providerFilter,
        QuotaWindowKind window = QuotaWindowKind.Session)
    {
        var menu = new MenuItem { Header = header };
        var providers = _latestTiles
            .Where(t => !string.IsNullOrEmpty(t.Id) && providerFilter(t.Id))
            .ToList();

        if (providers.Count == 0)
        {
            menu.Items.Add(new MenuItem { Header = "No providers yet", IsEnabled = false });
            return menu;
        }

        foreach (var tile in providers)
        {
            var id = tile.Id;
            var item = new MenuItem { Header = tile.Name };
            item.Click += (_, _) => AddWidgetAndRefresh(id, kind, window);
            menu.Items.Add(item);
        }
        return menu;
    }

    private void AddWidgetAndRefresh(string providerId, WidgetKind kind, QuotaWindowKind window)
    {
        _widgets.AddWidget(providerId, kind, window);
        // Refresh promptly so the new widget (especially cost) populates without waiting.
        _ = RefreshUsageAsync();
    }

    private async Task StartEngineAsync()
    {
        try
        {
            var exePath = AppPaths.ResolveCodexBarExe();
            var runtimeDir = AppPaths.ResolveSwiftRuntimeDir();
            _serve = new ServeProcess(exePath, runtimeDir);
            await _serve.StartAsync(TimeSpan.FromSeconds(15));

            _client = new UsageClient(_serve.BaseUrl);
            SetStatus($"Connected — port {_serve.Port}");
            await RefreshUsageAsync();
            StartRefreshTimer();
        }
        catch (Exception ex)
        {
            SetStatus($"Engine error: {ex.Message}");
        }
    }

    private void StartRefreshTimer()
    {
        _refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        _refreshTimer.Tick += async (_, _) => await RefreshUsageAsync();
        _refreshTimer.Start();
    }

    private async Task RefreshUsageAsync()
    {
        if (_client is null || _serve is null || _refreshing) return;
        if (!_serve.IsRunning)
        {
            SetStatus("Engine stopped");
            return;
        }

        _refreshing = true;
        _usageVm.Status = "Refreshing…";
        try
        {
            var json = await _client.GetUsageJsonAsync();
            var results = UsageJson.Parse(json);
            var tiles = UsageViewModelBuilder.Build(results).ToList();
            var maxPercent = tiles
                .SelectMany(t => t.Windows)
                .Select(w => w.UsedPercent)
                .DefaultIfEmpty(0)
                .Max();
            var prefs = new NotificationPrefs(
                _ui.SessionQuotaNotificationsEnabled,
                _ui.QuotaWarningNotificationsEnabled,
                _ui.QuotaWarningThresholds);
            var notifications = _notifications.Evaluate(results, prefs);

            // Only pay for /cost when a cost widget is actually pinned. The widget
            // list lives on the UI thread, so read the flag there.
            var costs = new List<CostResult>();
            if (Dispatcher.Invoke(() => _widgets.NeedsCost))
            {
                try { costs = CostJson.Parse(await _client.GetCostJsonAsync()); }
                catch { /* cost is best-effort; leave empty on failure */ }
            }
            var widgetData = new WidgetData(tiles, results, costs);

            Dispatcher.Invoke(() =>
            {
                _usageVm.Replace(tiles);
                _usageVm.Status = $"Updated {DateTime.Now:HH:mm}";
                UpdateTrayIcon(maxPercent / 100.0, connected: true);
                foreach (var notification in notifications) ShowNotification(notification);
                _latestTiles = tiles;
                _widgets.UpdateData(widgetData);
            });
            SetTooltip(tiles.Count == 0
                ? "CodexBar — no providers enabled"
                : $"CodexBar — {Math.Round(maxPercent)}% peak across {tiles.Count} provider(s)");
        }
        catch (Exception ex)
        {
            _usageVm.Status = "Fetch failed";
            Dispatcher.Invoke(() => UpdateTrayIcon(0, connected: false));
            SetTooltip($"CodexBar — fetch failed: {ex.Message}");
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void SetStatus(string status)
    {
        void Apply()
        {
            if (_statusItem is not null) _statusItem.Header = status;
            _usageVm.Status = status;
            if (_trayIcon is not null) _trayIcon.ToolTipText = $"CodexBar — {status}";
        }

        if (Dispatcher.CheckAccess()) Apply();
        else Dispatcher.Invoke(Apply);
    }

    private void OpenSettings()
    {
        if (_settingsWindow is not null)
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_config, _ui, onChanged: () => _ = RefreshUsageAsync());
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
    }

    private void ShowNotification(NotificationItem item)
    {
        // Shell balloon notifications (routed through the Action Center on Win 10/11);
        // no app packaging or extra dependency required.
        _trayIcon?.ShowBalloonTip(
            item.Title,
            item.Body,
            item.IsWarning ? BalloonIcon.Warning : BalloonIcon.Info);
    }

    private void UpdateTrayIcon(double fraction, bool connected)
    {
        if (_trayIcon is not null)
        {
            _trayIcon.IconSource = TrayIconFactory.Render(fraction, connected);
        }
    }

    private void SetTooltip(string tooltip)
    {
        void Apply()
        {
            if (_trayIcon is not null) _trayIcon.ToolTipText = tooltip;
        }

        if (Dispatcher.CheckAccess()) Apply();
        else Dispatcher.Invoke(Apply);
    }

    private void OnExit(object sender, ExitEventArgs e)
    {
        _refreshTimer?.Stop();
        _widgets.CloseAll();
        _usageWindow?.Close();
        _client?.Dispose();
        _serve?.Dispose();
        _trayIcon?.Dispose();
    }
}
