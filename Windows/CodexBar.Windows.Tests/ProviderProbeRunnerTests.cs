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
        using var temp = new TempDirectory();
        var scriptPath = Path.Combine(temp.Path, "probe.cmd");
        await File.WriteAllLinesAsync(scriptPath,
        [
            "@echo off",
            "echo ignored",
            "echo {\"health\":\"ok\",\"remaining\":7,\"limit\":9}",
        ]);

        var runner = new ProviderProbeRunner();

        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "codex",
                Name = "Codex",
                Command = "cmd.exe",
                Arguments = ["/c", scriptPath],
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Healthy, snapshot.Health);
        Assert.Equal(7, snapshot.Remaining);
        Assert.Equal(9, snapshot.Limit);
    }

    [WindowsFact]
    public async Task LoadProviderAsync_ParsesCodexBarCliJsonArray()
    {
        using var temp = new TempDirectory();
        var scriptPath = Path.Combine(temp.Path, "probe.cmd");
        await File.WriteAllLinesAsync(scriptPath,
        [
            "@echo off",
            "echo [{\"provider\":\"claude\",\"source\":\"claude-cli\",\"status\":{\"indicator\":\"none\",\"url\":\"https://status.example.com\"},\"usage\":{\"primary\":{\"usedPercent\":25,\"windowMinutes\":300,\"resetsAt\":\"2026-06-10T10:00:00Z\"},\"updatedAt\":\"2026-06-06T10:00:00Z\"},\"credits\":null,\"error\":null}]",
        ]);

        var runner = new ProviderProbeRunner();

        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "claude",
                Name = "Claude",
                Command = "cmd.exe",
                Arguments = ["/c", scriptPath],
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Healthy, snapshot.Health);
        Assert.Equal("session", snapshot.Window);
        Assert.Equal(75, snapshot.Remaining);
        Assert.Equal(100, snapshot.Limit);
        Assert.Equal("% left", snapshot.Unit);
        Assert.Equal(new DateTimeOffset(2026, 6, 10, 10, 0, 0, TimeSpan.Zero), snapshot.ResetsAt);
        Assert.Equal("https://status.example.com", snapshot.SourceUrl);
    }

    [WindowsFact]
    public async Task LoadProviderAsync_ParsesPrettyJsonArrayBetweenLogLines()
    {
        using var temp = new TempDirectory();
        var scriptPath = Path.Combine(temp.Path, "pretty-probe.cmd");
        await File.WriteAllLinesAsync(scriptPath,
        [
            "@echo off",
            "echo warning: refreshing cache",
            "echo [",
            "echo   {\"provider\":\"claude\",\"source\":\"claude-cli\",\"status\":{\"indicator\":\"none\",\"url\":\"https://status.example.com\"},\"usage\":{\"primary\":{\"usedPercent\":40,\"windowMinutes\":10080},\"updatedAt\":\"2026-06-06T10:00:00Z\"},\"credits\":null,\"error\":null}",
            "echo ]",
            "echo done",
        ]);

        var runner = new ProviderProbeRunner();

        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "claude",
                Name = "Claude",
                Command = "cmd.exe",
                Arguments = ["/c", scriptPath],
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Healthy, snapshot.Health);
        Assert.Equal("weekly", snapshot.Window);
        Assert.Equal(60, snapshot.Remaining);
    }

    [WindowsFact]
    public async Task LoadProviderAsync_SkipsMalformedJsonLikeLogText()
    {
        using var temp = new TempDirectory();
        var scriptPath = Path.Combine(temp.Path, "logged-probe.cmd");
        await File.WriteAllLinesAsync(scriptPath,
        [
            "@echo off",
            "echo [warn] ignored",
            "echo {\"health\":\"ok\",\"remaining\":7,\"limit\":9}",
        ]);

        var runner = new ProviderProbeRunner();

        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "codex",
                Name = "Codex",
                Command = "cmd.exe",
                Arguments = ["/c", scriptPath],
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Healthy, snapshot.Health);
        Assert.Equal(7, snapshot.Remaining);
        Assert.Equal(9, snapshot.Limit);
    }

    [WindowsFact]
    public async Task LoadProviderAsync_ReturnsFailedSnapshotWhenCommandTimesOut()
    {
        using var temp = new TempDirectory();
        var scriptPath = Path.Combine(temp.Path, "hang.cmd");
        await File.WriteAllLinesAsync(scriptPath,
        [
            "@echo off",
            "ping -n 30 127.0.0.1 >nul",
        ]);

        var runner = new ProviderProbeRunner();

        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "codex",
                Name = "Codex",
                Command = "cmd.exe",
                Arguments = ["/c", scriptPath],
                TimeoutSeconds = 1,
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Failing, snapshot.Health);
        Assert.Contains("timed out", snapshot.Detail);
    }

    [WindowsFact]
    public async Task LoadProviderAsync_ReturnsFailedSnapshotWhenOutputDrainTimesOut()
    {
        using var temp = new TempDirectory();
        var scriptPath = Path.Combine(temp.Path, "pipe-hang.cmd");
        await File.WriteAllLinesAsync(scriptPath,
        [
            "@echo off",
            "start /b cmd /c \"ping -n 30 127.0.0.1 >nul\"",
            "echo {\"health\":\"ok\",\"remaining\":7,\"limit\":9}",
        ]);

        var runner = new ProviderProbeRunner();

        var snapshot = await runner.LoadProviderAsync(
            new ProviderProbeSettings
            {
                Id = "codex",
                Name = "Codex",
                Command = "cmd.exe",
                Arguments = ["/c", scriptPath],
                TimeoutSeconds = 1,
            },
            CancellationToken.None);

        Assert.Equal(ProviderHealth.Failing, snapshot.Health);
        Assert.Contains("timed out", snapshot.Detail);
    }
}
