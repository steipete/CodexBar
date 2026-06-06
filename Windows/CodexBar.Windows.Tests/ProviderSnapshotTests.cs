using CodexBar.Windows.Core;

namespace CodexBar.Windows.Tests;

public sealed class ProviderSnapshotTests
{
    [Fact]
    public void Parse_AcceptsCodexBarProbeShape()
    {
        var json = """
            {
              "id": "codex",
              "name": "Codex",
              "health": "warning",
              "window": "weekly",
              "remaining": 12.5,
              "limit": 100,
              "unit": "credits",
              "resetsAt": "2026-06-08T12:00:00Z",
              "updatedAt": "2026-06-06T12:00:00Z",
              "detail": "near weekly limit",
              "sourceUrl": "https://codexbar.app"
            }
            """;

        var settings = new ProviderProbeSettings { Id = "fallback", Name = "Fallback" };
        var snapshot = ProviderSnapshotJson.Parse(json).ToSnapshot(settings);

        Assert.Equal("codex", snapshot.Id);
        Assert.Equal("Codex", snapshot.Name);
        Assert.Equal(ProviderHealth.Warning, snapshot.Health);
        Assert.Equal("weekly", snapshot.Window);
        Assert.Equal(12.5, snapshot.Remaining);
        Assert.Equal(100, snapshot.Limit);
        Assert.Equal(0.875, snapshot.UsageFraction);
        Assert.Contains("near weekly limit", snapshot.Detail);
    }

    [Fact]
    public void Summary_UsesProviderFallbacksWhenProbeOmitsIdentity()
    {
        var settings = new ProviderProbeSettings { Id = "claude", Name = "Claude" };
        var snapshot = ProviderSnapshotJson.Parse("""{"health":"ok","remaining":8,"limit":10}""").ToSnapshot(settings);

        Assert.Equal("claude", snapshot.Id);
        Assert.Equal("Claude", snapshot.Name);
        Assert.Equal(ProviderHealth.Healthy, snapshot.Health);
        Assert.Contains("8 / 10", snapshot.Summary);
        Assert.Contains("[ok] Claude", snapshot.MenuLabel);
    }
}
