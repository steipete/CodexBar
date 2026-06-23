using System.Windows;
using System.Windows.Controls;

namespace CodexBarTray;

public partial class SettingsWindow : Window
{
    private readonly ConfigService _config;
    private readonly UiSettings _ui;
    private readonly Action _onChanged;
    private bool _loadingNotificationsUi;

    public SettingsWindow(ConfigService config, UiSettings ui, Action onChanged)
    {
        _config = config;
        _ui = ui;
        _onChanged = onChanged;
        InitializeComponent();
        InitNotificationsUi();
        Loaded += async (_, _) => await LoadAsync();
    }

    private void InitNotificationsUi()
    {
        _loadingNotificationsUi = true;
        SessionNotifyCheck.IsChecked = _ui.SessionQuotaNotificationsEnabled;
        WarningNotifyCheck.IsChecked = _ui.QuotaWarningNotificationsEnabled;
        ThresholdsBox.Text = string.Join(", ", _ui.QuotaWarningThresholds);
        _loadingNotificationsUi = false;
    }

    private void OnNotificationToggleChanged(object sender, RoutedEventArgs e)
    {
        if (_loadingNotificationsUi) return;
        _ui.SessionQuotaNotificationsEnabled = SessionNotifyCheck.IsChecked == true;
        _ui.QuotaWarningNotificationsEnabled = WarningNotifyCheck.IsChecked == true;
        _ui.Save();
    }

    private void OnThresholdsChanged(object sender, RoutedEventArgs e)
    {
        if (_loadingNotificationsUi) return;
        var parsed = ThresholdsBox.Text
            .Split(new[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(s => int.TryParse(s, out var value) ? value : -1)
            .Where(value => value >= 0)
            .ToList();
        _ui.QuotaWarningThresholds = QuotaThresholds.Sanitized(parsed);
        InitNotificationsUi(); // reflect the sanitized list back into the box
        _ui.Save();
    }

    private async Task LoadAsync()
    {
        try
        {
            GlobalStatus.Text = "Loading providers…";
            var providers = await _config.GetProvidersAsync();
            var keyPresence = await _config.GetKeyPresenceAsync();

            var rows = providers.Select(p => new ProviderSettingRow
            {
                Id = p.Provider,
                DisplayName = p.DisplayName,
                AuthKind = AuthClassifier.Classify(p.Provider),
                Enabled = p.Enabled,
                HasKey = keyPresence.TryGetValue(p.Provider, out var has) && has,
            }).ToList();

            ProviderList.ItemsSource = rows;
            GlobalStatus.Text = $"{rows.Count} providers";
        }
        catch (Exception ex)
        {
            GlobalStatus.Text = $"Failed to load: {ex.Message}";
        }
    }

    private async void OnEnabledClick(object sender, RoutedEventArgs e)
    {
        if (sender is not CheckBox { DataContext: ProviderSettingRow row } checkBox) return;
        var enabled = checkBox.IsChecked == true;
        try
        {
            await _config.SetEnabledAsync(row.Id, enabled);
            row.Enabled = enabled;
            row.Status = enabled ? "enabled" : "disabled";
            _onChanged();
        }
        catch (Exception ex)
        {
            // Revert the visual toggle on failure.
            checkBox.IsChecked = row.Enabled;
            row.Status = $"failed: {ex.Message}";
        }
    }

    private async void OnSaveKeyClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: ProviderSettingRow row } button) return;
        if (button.CommandParameter is not PasswordBox keyBox) return;

        var key = keyBox.Password;
        if (string.IsNullOrWhiteSpace(key))
        {
            row.Status = "enter a key first";
            return;
        }

        try
        {
            await _config.SetApiKeyAsync(row.Id, key);
            keyBox.Clear();
            row.HasKey = true;
            row.Enabled = true; // set-api-key auto-enables
            row.Status = "key saved — provider enabled";
            _onChanged();
        }
        catch (Exception ex)
        {
            row.Status = $"failed: {ex.Message}";
        }
    }
}
