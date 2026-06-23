using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Media;

namespace CodexBarTray;

/// <summary>Root view model bound by the popup: the provider tiles plus a status line.</summary>
public sealed class UsageViewModel : INotifyPropertyChanged
{
    public ObservableCollection<ProviderViewModel> Providers { get; } = new();

    private string _status = "Loading…";
    public string Status
    {
        get => _status;
        set { _status = value; OnPropertyChanged(nameof(Status)); }
    }

    public void Replace(IEnumerable<ProviderViewModel> providers)
    {
        Providers.Clear();
        foreach (var provider in providers) Providers.Add(provider);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class ProviderViewModel
{
    public string Name { get; init; } = "";
    public string? Account { get; init; }
    public bool HasError { get; init; }
    public string? ErrorMessage { get; init; }
    public List<RateWindowViewModel> Windows { get; init; } = new();

    public bool HasAccount => !string.IsNullOrWhiteSpace(Account);
    public bool HasWindows => Windows.Count > 0;
}

public sealed class RateWindowViewModel
{
    public string Label { get; init; } = "";
    public double UsedPercent { get; init; }
    public string PercentText => $"{Math.Round(UsedPercent)}%";
    public string ResetText { get; init; } = "";
    public Brush BarBrush => UsageColors.ForUsedPercent(UsedPercent);
}

public static class UsageColors
{
    public static readonly Brush Track = Freeze(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));
    private static readonly Brush Teal = Freeze(Color.FromRgb(0x16, 0xD3, 0xB4));
    private static readonly Brush Amber = Freeze(Color.FromRgb(0xE5, 0xA5, 0x0A));
    private static readonly Brush Red = Freeze(Color.FromRgb(0xE0, 0x48, 0x3B));

    public static Brush ForUsedPercent(double used) =>
        used >= 85 ? Red : used >= 60 ? Amber : Teal;

    private static Brush Freeze(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}

/// <summary>Builds provider tiles from the raw /usage results.</summary>
public static class UsageViewModelBuilder
{
    private static readonly Dictionary<string, string> DisplayNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["codex"] = "Codex", ["openai"] = "OpenAI", ["claude"] = "Claude", ["cursor"] = "Cursor",
        ["gemini"] = "Gemini", ["copilot"] = "Copilot", ["grok"] = "Grok", ["openrouter"] = "OpenRouter",
        ["elevenlabs"] = "ElevenLabs", ["deepgram"] = "Deepgram", ["zai"] = "z.ai", ["minimax"] = "MiniMax",
        ["kiro"] = "Kiro", ["zed"] = "Zed", ["augment"] = "Augment", ["windsurf"] = "Windsurf",
        ["mistral"] = "Mistral", ["deepseek"] = "DeepSeek", ["bedrock"] = "AWS Bedrock",
    };

    public static IEnumerable<ProviderViewModel> Build(IEnumerable<ProviderResult> results)
    {
        foreach (var result in results)
        {
            var account = result.Usage?.Identity?.AccountEmail ?? result.Account;
            yield return new ProviderViewModel
            {
                Name = DisplayName(result.Provider),
                Account = account,
                HasError = result.Error is not null,
                ErrorMessage = result.Error?.Message,
                Windows = BuildWindows(result.Usage),
            };
        }
    }

    private static List<RateWindowViewModel> BuildWindows(UsageData? usage)
    {
        var windows = new List<RateWindowViewModel>();
        if (usage is null) return windows;

        AddWindow(windows, usage.Primary, LabelForMinutes(usage.Primary?.WindowMinutes, "Session"));
        AddWindow(windows, usage.Secondary, LabelForMinutes(usage.Secondary?.WindowMinutes, "Secondary"));
        AddWindow(windows, usage.Tertiary, LabelForMinutes(usage.Tertiary?.WindowMinutes, "Tertiary"));

        if (usage.ExtraRateWindows is not null)
        {
            foreach (var extra in usage.ExtraRateWindows)
            {
                AddWindow(windows, extra.Window, extra.Title ?? extra.Id ?? "Window");
            }
        }
        return windows;
    }

    private static void AddWindow(List<RateWindowViewModel> windows, RateWindow? window, string label)
    {
        if (window is null) return;
        windows.Add(new RateWindowViewModel
        {
            Label = label,
            UsedPercent = window.UsedPercent,
            ResetText = ResetText(window),
        });
    }

    private static string ResetText(RateWindow window)
    {
        if (window.ResetsAt is { } resetsAt)
        {
            var remaining = resetsAt - DateTimeOffset.Now;
            if (remaining > TimeSpan.Zero)
            {
                var human = remaining.TotalDays >= 1
                    ? $"{(int)remaining.TotalDays}d {remaining.Hours}h"
                    : remaining.TotalHours >= 1
                        ? $"{(int)remaining.TotalHours}h {remaining.Minutes}m"
                        : $"{remaining.Minutes}m";
                return $"resets in {human}";
            }
        }
        return window.ResetDescription is { Length: > 0 } desc ? $"resets {desc}" : "";
    }

    private static string LabelForMinutes(int? minutes, string fallback) => minutes switch
    {
        null => fallback,
        300 => "5h",
        60 => "1h",
        1440 => "Daily",
        10080 => "Weekly",
        43200 => "Monthly",
        var m when m % 1440 == 0 => $"{m / 1440}d",
        var m when m % 60 == 0 => $"{m / 60}h",
        var m => $"{m}m",
    };

    public static string DisplayName(string id) =>
        DisplayNames.TryGetValue(id, out var name)
            ? name
            : id.Length == 0 ? id : char.ToUpperInvariant(id[0]) + id[1..];
}
