using System.Text.Json;
using CodexBar.Windows.Core;

namespace CodexBar.Windows.Tests;

public sealed class WindowsSettingsStoreTests
{
    [Fact]
    public void LoadOrCreate_CreatesDefaultSettingsAndSampleSnapshot()
    {
        using var temp = new TempDirectory();

        var store = WindowsSettingsStore.LoadOrCreate(temp.Path);

        Assert.True(File.Exists(store.SettingsPath));
        Assert.True(File.Exists(Path.Combine(temp.Path, "codex.sample.json")));
        Assert.Contains(store.Settings.Providers, provider => provider.Id == "codex");
        Assert.Contains(store.Settings.Providers, provider => provider.Id == "claude" && provider.Enabled == false);
    }

    [Fact]
    public void LoadOrCreate_NormalizesInvalidProvidersAndTimeouts()
    {
        using var temp = new TempDirectory();
        var settingsPath = Path.Combine(temp.Path, "windows-settings.json");
        var raw = new
        {
            refreshIntervalMinutes = 5,
            providers = new object[]
            {
                new { id = " codex ", name = " Codex ", timeoutSeconds = 999 },
                new { id = "", name = "Broken" },
            },
        };
        File.WriteAllText(settingsPath, JsonSerializer.Serialize(raw));

        var store = WindowsSettingsStore.LoadOrCreate(temp.Path);

        var provider = Assert.Single(store.Settings.Providers);
        Assert.Equal("codex", provider.Id);
        Assert.Equal("Codex", provider.Name);
        Assert.Equal(300, provider.TimeoutSeconds);
    }
}
