using CodexBar.Windows.Core;

namespace CodexBar.Windows.Tests;

public sealed class ProviderProbeRunnerTests
{
    [Fact]
    public async Task LoadProviderAsync_ReadsSnapshotFile()
    {
        using var temp = new TempDirectory();
        var snapshotPath = Path.Combine(temp.Path, "codex.json");
        await File.WriteAllTextAsync(snapshotPath, """{"health":"healthy","remaining":40,"limit":100}""");

        var runner = new ProviderProbeRunner();
        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "codex",
                Name = "Codex",
                SnapshotPath = snapshotPath,
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Healthy, snapshot.Health);
        Assert.Equal(40, snapshot.Remaining);
        Assert.Equal(100, snapshot.Limit);
    }

    [Fact]
    public async Task LoadProviderAsync_ReturnsUnknownForMissingSnapshot()
    {
        using var temp = new TempDirectory();
        var runner = new ProviderProbeRunner();

        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "codex",
                Name = "Codex",
                SnapshotPath = Path.Combine(temp.Path, "missing.json"),
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Unknown, snapshot.Health);
        Assert.Contains("Snapshot not found", snapshot.Detail);
    }

    [WindowsFact]
    public async Task LoadProviderAsync_ParsesCommandJsonLine()
    {
        var runner = new ProviderProbeRunner();

        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "codex",
                Name = "Codex",
                Command = "cmd.exe",
                Arguments = ["/c", "echo ignored && echo {\"health\":\"ok\",\"remaining\":7,\"limit\":9}"],
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Healthy, snapshot.Health);
        Assert.Equal(7, snapshot.Remaining);
        Assert.Equal(9, snapshot.Limit);
    }
}
