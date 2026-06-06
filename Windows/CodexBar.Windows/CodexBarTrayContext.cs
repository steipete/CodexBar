using System.Diagnostics;
using CodexBar.Windows.Core;

namespace CodexBar.Windows;

internal sealed class CodexBarTrayContext : ApplicationContext
{
    private readonly WindowsSettingsStore _settingsStore;
    private readonly ProviderProbeRunner _probeRunner;
    private readonly NotifyIcon _notifyIcon;
    private readonly ContextMenuStrip _menu = new();
    private readonly System.Windows.Forms.Timer _refreshTimer = new();
    private readonly CancellationTokenSource _shutdown = new();
    private IReadOnlyList<ProviderSnapshot> _snapshots = [];
    private bool _isRefreshing;
    private string? _lastError;

    public CodexBarTrayContext(WindowsSettingsStore settingsStore, ProviderProbeRunner probeRunner)
    {
        _settingsStore = settingsStore;
        _probeRunner = probeRunner;
        _notifyIcon = new NotifyIcon
        {
            Icon = TrayIconFactory.Create(ProviderHealth.Unknown),
            Text = "CodexBar",
            ContextMenuStrip = _menu,
            Visible = true,
        };

        _notifyIcon.MouseUp += OnNotifyIconMouseUp;

        _refreshTimer.Interval = Math.Clamp(settingsStore.Settings.RefreshIntervalMinutes, 1, 60) * 60 * 1000;
        _refreshTimer.Tick += (_, _) => BeginRefresh();
        _refreshTimer.Start();

        BuildMenu();
        BeginRefresh();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _shutdown.Cancel();
            _refreshTimer.Stop();
            _refreshTimer.Dispose();
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _shutdown.Dispose();
            _menu.Dispose();
        }

        base.Dispose(disposing);
    }

    private void BeginRefresh()
    {
        if (_isRefreshing)
        {
            return;
        }

        _ = RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        _isRefreshing = true;
        _lastError = null;
        BuildMenu();

        try
        {
            _snapshots = await _probeRunner.LoadAsync(_settingsStore.Settings.Providers, _shutdown.Token);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            _lastError = exception.Message;
        }
        finally
        {
            _isRefreshing = false;
            if (!_shutdown.IsCancellationRequested)
            {
                UpdateTrayIcon();
                BuildMenu();
            }
        }
    }

    private void BuildMenu()
    {
        _menu.Items.Clear();
        _menu.Items.Add(new ToolStripMenuItem(BuildHeaderText()) { Enabled = false });
        _menu.Items.Add(new ToolStripSeparator());

        if (_settingsStore.Settings.Providers.Count == 0)
        {
            _menu.Items.Add(new ToolStripMenuItem("No providers configured") { Enabled = false });
            _menu.Items.Add(new ToolStripMenuItem("Open settings file", null, (_, _) => OpenFile(_settingsStore.SettingsPath)));
            _menu.Items.Add(new ToolStripMenuItem("Open Windows setup doc", null, (_, _) => OpenUrl("https://github.com/steipete/CodexBar/blob/main/docs/windows.md")));
        }
        else if (_snapshots.Count == 0)
        {
            foreach (var provider in _settingsStore.Settings.Providers.Where(provider => provider.Enabled))
            {
                _menu.Items.Add(new ToolStripMenuItem($"[ ] {provider.Name}") { Enabled = false });
            }
        }
        else
        {
            foreach (var snapshot in _snapshots)
            {
                _menu.Items.Add(BuildProviderMenu(snapshot));
            }
        }

        if (!string.IsNullOrWhiteSpace(_lastError))
        {
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(new ToolStripMenuItem($"Error: {_lastError}") { Enabled = false });
        }

        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(new ToolStripMenuItem(_isRefreshing ? "Refreshing..." : "Refresh now", null, (_, _) => BeginRefresh()) { Enabled = !_isRefreshing });
        _menu.Items.Add(new ToolStripMenuItem("Open settings file", null, (_, _) => OpenFile(_settingsStore.SettingsPath)));
        _menu.Items.Add(new ToolStripMenuItem("Open Windows setup doc", null, (_, _) => OpenUrl("https://github.com/steipete/CodexBar/blob/main/docs/windows.md")));
        _menu.Items.Add(new ToolStripMenuItem("Quit CodexBar", null, (_, _) => ExitThread()));
    }

    private static ToolStripMenuItem BuildProviderMenu(ProviderSnapshot snapshot)
    {
        var item = new ToolStripMenuItem(snapshot.MenuLabel);

        item.DropDownItems.Add(new ToolStripMenuItem(snapshot.Summary) { Enabled = false });
        item.DropDownItems.Add(new ToolStripMenuItem(snapshot.ResetSummary) { Enabled = false });

        if (snapshot.UpdatedAt != null)
        {
            item.DropDownItems.Add(new ToolStripMenuItem($"Updated: {snapshot.UpdatedAt.Value.LocalDateTime:g}") { Enabled = false });
        }

        if (!string.IsNullOrWhiteSpace(snapshot.Detail))
        {
            item.DropDownItems.Add(new ToolStripMenuItem(snapshot.Detail) { Enabled = false });
        }

        if (!string.IsNullOrWhiteSpace(snapshot.SourceUrl))
        {
            item.DropDownItems.Add(new ToolStripSeparator());
            item.DropDownItems.Add(new ToolStripMenuItem("Open source", null, (_, _) => OpenUrl(snapshot.SourceUrl)));
        }

        return item;
    }

    private string BuildHeaderText()
    {
        var enabledCount = _settingsStore.Settings.Providers.Count(provider => provider.Enabled);
        var refreshState = _isRefreshing ? "refreshing" : "ready";
        return $"CodexBar Windows - {enabledCount} providers - {refreshState}";
    }

    private void UpdateTrayIcon()
    {
        var health = WorstHealth();
        var oldIcon = _notifyIcon.Icon;
        _notifyIcon.Icon = TrayIconFactory.Create(health);
        oldIcon?.Dispose();
        _notifyIcon.Text = BuildTooltip(health);
    }

    private ProviderHealth WorstHealth()
    {
        if (_lastError != null || _snapshots.Any(snapshot => snapshot.Health == ProviderHealth.Failing))
        {
            return ProviderHealth.Failing;
        }

        if (_snapshots.Any(snapshot => snapshot.Health == ProviderHealth.Warning))
        {
            return ProviderHealth.Warning;
        }

        if (_snapshots.Any(snapshot => snapshot.Health == ProviderHealth.Busy))
        {
            return ProviderHealth.Busy;
        }

        if (_snapshots.Count > 0 && _snapshots.All(snapshot => snapshot.Health == ProviderHealth.Healthy))
        {
            return ProviderHealth.Healthy;
        }

        return ProviderHealth.Unknown;
    }

    private string BuildTooltip(ProviderHealth health)
    {
        var summary = health switch
        {
            ProviderHealth.Healthy => "healthy",
            ProviderHealth.Busy => "refreshing",
            ProviderHealth.Warning => "quota warning",
            ProviderHealth.Failing => "needs attention",
            _ => "ready",
        };
        return $"CodexBar - {_snapshots.Count} providers - {summary}";
    }

    private void OnNotifyIconMouseUp(object? sender, MouseEventArgs eventArgs)
    {
        if (eventArgs.Button == MouseButtons.Left && _settingsStore.Settings.OpenMenuOnLeftClick)
        {
            _menu.Show(Cursor.Position);
        }
    }

    private static void OpenFile(string path)
    {
        StartShell(path);
    }

    private static void OpenUrl(string url)
    {
        StartShell(url);
    }

    private static void StartShell(string target)
    {
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "CodexBar", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
