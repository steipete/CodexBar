using System.IO;
using System.Text.Json;

namespace CodexBarTray;

/// <summary>
/// UI-only preferences for the tray usage window: whether it stays pinned on
/// screen (always-on-top, no auto-hide) and the last position the user dragged
/// it to. Persisted to <c>%LocalAppData%\CodexBar\ui-settings.json</c> so it
/// survives restarts, independent of the Swift engine's own provider config.
/// </summary>
public sealed class UiSettings
{
    public bool AlwaysOnScreen { get; set; }
    public double? WindowLeft { get; set; }
    public double? WindowTop { get; set; }

    // Notification preferences. Defaults match the macOS app (notifications on,
    // warning thresholds at 50% and 20% remaining). Absent keys in an existing
    // settings file fall back to these initializers.
    public bool SessionQuotaNotificationsEnabled { get; set; } = true;
    public bool QuotaWarningNotificationsEnabled { get; set; } = true;
    public List<int> QuotaWarningThresholds { get; set; } = new() { 50, 20 };

    private static string FilePath
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CodexBar");
            return Path.Combine(dir, "ui-settings.json");
        }
    }

    public static UiSettings Load()
    {
        try
        {
            var path = FilePath;
            if (File.Exists(path))
            {
                var json = File.ReadAllText(path);
                return JsonSerializer.Deserialize<UiSettings>(json) ?? new UiSettings();
            }
        }
        catch { /* fall back to defaults on any read/parse error */ }
        return new UiSettings();
    }

    public void Save()
    {
        try
        {
            var path = FilePath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(path, json);
        }
        catch { /* best-effort; UI prefs are non-critical */ }
    }
}
