using System.Text.Json;

namespace CodexBar.Windows.Core;

public sealed class WindowsSettings
{
    public int RefreshIntervalMinutes { get; set; } = 5;
    public bool OpenMenuOnLeftClick { get; set; } = true;
    public List<ProviderProbeSettings> Providers { get; set; } = [];
}

public sealed class ProviderProbeSettings
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public bool Enabled { get; set; } = true;
    public string? SnapshotPath { get; set; }
    public string? Command { get; set; }
    public List<string> Arguments { get; set; } = [];
    public string? WorkingDirectory { get; set; }
    public int TimeoutSeconds { get; set; } = 20;

    public bool IsValid => !string.IsNullOrWhiteSpace(Id) && !string.IsNullOrWhiteSpace(Name);
}

public sealed class WindowsSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private WindowsSettingsStore(string settingsPath, WindowsSettings settings)
    {
        SettingsPath = settingsPath;
        Settings = settings;
    }

    public string SettingsPath { get; }
    public WindowsSettings Settings { get; }

    public static string DefaultSettingsDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CodexBar");

    public static WindowsSettingsStore LoadOrCreate(string? settingsDirectory = null)
    {
        var directory = settingsDirectory ?? DefaultSettingsDirectory;
        Directory.CreateDirectory(directory);

        var settingsPath = Path.Combine(directory, "windows-settings.json");
        if (!File.Exists(settingsPath))
        {
            var sample = CreateDefault(directory);
            File.WriteAllText(settingsPath, JsonSerializer.Serialize(sample, JsonOptions));
            WriteSampleSnapshot(directory);
            return new WindowsSettingsStore(settingsPath, sample);
        }

        var raw = File.ReadAllText(settingsPath);
        var settings = JsonSerializer.Deserialize<WindowsSettings>(raw, JsonOptions) ?? new WindowsSettings();
        settings.Providers ??= [];
        settings.Providers = settings.Providers
            .Where(provider => provider.IsValid)
            .Select(NormalizeProvider)
            .ToList();

        return new WindowsSettingsStore(settingsPath, settings);
    }

    public static WindowsSettings CreateDefault(string settingsDirectory)
    {
        return new WindowsSettings
        {
            Providers =
            [
                new ProviderProbeSettings
                {
                    Id = "codex",
                    Name = "Codex",
                    SnapshotPath = Path.Combine(settingsDirectory, "codex.sample.json"),
                },
                new ProviderProbeSettings
                {
                    Id = "claude",
                    Name = "Claude",
                    Enabled = false,
                    Command = "codexbar",
                    Arguments = ["usage", "--provider", "claude", "--json"],
                },
            ],
        };
    }

    private static ProviderProbeSettings NormalizeProvider(ProviderProbeSettings provider)
    {
        return new ProviderProbeSettings
        {
            Id = provider.Id.Trim(),
            Name = provider.Name.Trim(),
            Enabled = provider.Enabled,
            SnapshotPath = NormalizeOptional(provider.SnapshotPath),
            Command = NormalizeOptional(provider.Command),
            Arguments = provider.Arguments?.Where(argument => argument != null).ToList() ?? [],
            WorkingDirectory = NormalizeOptional(provider.WorkingDirectory),
            TimeoutSeconds = Math.Clamp(provider.TimeoutSeconds <= 0 ? 20 : provider.TimeoutSeconds, 1, 300),
        };
    }

    private static void WriteSampleSnapshot(string settingsDirectory)
    {
        var snapshotPath = Path.Combine(settingsDirectory, "codex.sample.json");
        if (File.Exists(snapshotPath))
        {
            return;
        }

        var sample = new ProviderSnapshotJson
        {
            Id = "codex",
            Name = "Codex",
            Health = "healthy",
            Window = "weekly",
            Remaining = 42,
            Limit = 100,
            Unit = "credits left",
            ResetsAt = DateTimeOffset.UtcNow.AddDays(2),
            UpdatedAt = DateTimeOffset.UtcNow,
            Detail = "Replace this sample with a real provider probe.",
            SourceUrl = "https://codexbar.app",
        };
        File.WriteAllText(snapshotPath, JsonSerializer.Serialize(sample, JsonOptions));
    }

    private static string? NormalizeOptional(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? null : Environment.ExpandEnvironmentVariables(value.Trim());
    }
}
