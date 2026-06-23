using System.IO;
using System.Text.Json;

namespace CodexBarTray;

/// <summary>
/// One pinned desktop widget: which provider it shows and where it sits.
/// </summary>
public sealed class WidgetConfig
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string ProviderId { get; set; } = "";
    // Default 0 == Usage, so widgets saved before kinds existed restore as usage.
    public WidgetKind Kind { get; set; } = WidgetKind.Usage;
    public double? Left { get; set; }
    public double? Top { get; set; }
}

/// <summary>
/// Persists the set of desktop widgets to
/// <c>%LocalAppData%\CodexBar\widgets.json</c> so pinned widgets restore on
/// launch. Independent of UiSettings (panel prefs) and the Swift engine config.
/// </summary>
public sealed class WidgetStore
{
    public List<WidgetConfig> Widgets { get; set; } = new();

    private static string FilePath
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CodexBar");
            return Path.Combine(dir, "widgets.json");
        }
    }

    public static WidgetStore Load()
    {
        try
        {
            var path = FilePath;
            if (File.Exists(path))
            {
                var json = File.ReadAllText(path);
                return JsonSerializer.Deserialize<WidgetStore>(json) ?? new WidgetStore();
            }
        }
        catch { /* fall back to empty on any read/parse error */ }
        return new WidgetStore();
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
        catch { /* best-effort; widgets are non-critical */ }
    }
}
