using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexBar.Windows.Core;

public enum ProviderHealth
{
    Unknown,
    Healthy,
    Busy,
    Warning,
    Failing,
}

public sealed record ProviderSnapshot(
    string Id,
    string Name,
    ProviderHealth Health,
    string? Window,
    double? Remaining,
    double? Limit,
    string? Unit,
    DateTimeOffset? ResetsAt,
    DateTimeOffset? UpdatedAt,
    string? Detail,
    string? SourceUrl)
{
    public double? UsageFraction
    {
        get
        {
            if (Remaining is null || Limit is null || Limit <= 0)
            {
                return null;
            }

            return Math.Clamp(1 - Remaining.Value / Limit.Value, 0, 1);
        }
    }

    public string Summary
    {
        get
        {
            var window = string.IsNullOrWhiteSpace(Window) ? "usage" : Window;
            if (Remaining is not null && Limit is not null)
            {
                return $"{window}: {FormatNumber(Remaining.Value)} / {FormatNumber(Limit.Value)} {Unit ?? "left"}";
            }

            if (Remaining is not null)
            {
                return $"{window}: {FormatNumber(Remaining.Value)} {Unit ?? "left"}";
            }

            return Detail ?? "no usage snapshot";
        }
    }

    public string ResetSummary
    {
        get
        {
            if (ResetsAt is null)
            {
                return "reset unknown";
            }

            var remaining = ResetsAt.Value - DateTimeOffset.Now;
            if (remaining <= TimeSpan.Zero)
            {
                return $"reset {ResetsAt.Value.LocalDateTime:g}";
            }

            if (remaining.TotalHours >= 24)
            {
                return $"resets in {Math.Ceiling(remaining.TotalDays):0}d";
            }

            if (remaining.TotalHours >= 1)
            {
                return $"resets in {Math.Ceiling(remaining.TotalHours):0}h";
            }

            return $"resets in {Math.Max(1, Math.Ceiling(remaining.TotalMinutes)):0}m";
        }
    }

    public string MenuLabel => $"{HealthPrefix(Health)} {Name} - {Summary} - {ResetSummary}";

    public static ProviderSnapshot Unknown(string id, string name, string detail)
    {
        return new ProviderSnapshot(
            id,
            name,
            ProviderHealth.Unknown,
            Window: null,
            Remaining: null,
            Limit: null,
            Unit: null,
            ResetsAt: null,
            UpdatedAt: DateTimeOffset.UtcNow,
            Detail: detail,
            SourceUrl: null);
    }

    public static ProviderSnapshot Failed(string id, string name, string detail)
    {
        return new ProviderSnapshot(
            id,
            name,
            ProviderHealth.Failing,
            Window: null,
            Remaining: null,
            Limit: null,
            Unit: null,
            ResetsAt: null,
            UpdatedAt: DateTimeOffset.UtcNow,
            Detail: detail,
            SourceUrl: null);
    }

    private static string HealthPrefix(ProviderHealth health)
    {
        return health switch
        {
            ProviderHealth.Healthy => "[ok]",
            ProviderHealth.Busy => "[..]",
            ProviderHealth.Warning => "[!]",
            ProviderHealth.Failing => "[x]",
            _ => "[ ]",
        };
    }

    private static string FormatNumber(double value)
    {
        return value % 1 == 0
            ? value.ToString("0", CultureInfo.InvariantCulture)
            : value.ToString("0.##", CultureInfo.InvariantCulture);
    }
}

public sealed class ProviderSnapshotJson
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("name")]
    public string? Name { get; set; }

    [JsonPropertyName("health")]
    public string? Health { get; set; }

    [JsonPropertyName("window")]
    public string? Window { get; set; }

    [JsonPropertyName("remaining")]
    public double? Remaining { get; set; }

    [JsonPropertyName("limit")]
    public double? Limit { get; set; }

    [JsonPropertyName("unit")]
    public string? Unit { get; set; }

    [JsonPropertyName("resetsAt")]
    public DateTimeOffset? ResetsAt { get; set; }

    [JsonPropertyName("updatedAt")]
    public DateTimeOffset? UpdatedAt { get; set; }

    [JsonPropertyName("detail")]
    public string? Detail { get; set; }

    [JsonPropertyName("sourceUrl")]
    public string? SourceUrl { get; set; }

    public ProviderSnapshot ToSnapshot(ProviderProbeSettings settings)
    {
        return new ProviderSnapshot(
            Normalize(Id, settings.Id),
            Normalize(Name, settings.Name),
            ParseHealth(Health),
            NormalizeOptional(Window),
            Remaining,
            Limit,
            NormalizeOptional(Unit),
            ResetsAt,
            UpdatedAt ?? DateTimeOffset.UtcNow,
            NormalizeOptional(Detail),
            NormalizeOptional(SourceUrl));
    }

    public static ProviderSnapshotJson Parse(string json)
    {
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        };
        return JsonSerializer.Deserialize<ProviderSnapshotJson>(json, options) ??
            throw new InvalidOperationException("Snapshot JSON was empty.");
    }

    private static ProviderHealth ParseHealth(string? value)
    {
        return value?.Trim().ToLowerInvariant() switch
        {
            "ok" or "healthy" or "green" => ProviderHealth.Healthy,
            "busy" or "refreshing" or "running" => ProviderHealth.Busy,
            "warn" or "warning" or "yellow" => ProviderHealth.Warning,
            "fail" or "failed" or "failing" or "error" or "red" => ProviderHealth.Failing,
            _ => ProviderHealth.Unknown,
        };
    }

    private static string Normalize(string? value, string fallback)
    {
        return string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
    }

    private static string? NormalizeOptional(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }
}
