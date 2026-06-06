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

    public static ProviderSnapshot ParseSnapshot(string json, ProviderProbeSettings settings)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions
        {
            CommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        });

        return document.RootElement.ValueKind switch
        {
            JsonValueKind.Object => Parse(json).ToSnapshot(settings),
            JsonValueKind.Array => ParseCliPayloadArray(document.RootElement, settings),
            _ => throw new InvalidOperationException("Snapshot JSON must be an object or array."),
        };
    }

    private static ProviderSnapshot ParseCliPayloadArray(JsonElement payloads, ProviderProbeSettings settings)
    {
        var payload = SelectCliPayload(payloads, settings);
        if (TryGetObject(payload, "error", out var error))
        {
            return ProviderSnapshot.Failed(
                Normalize(GetString(payload, "provider"), settings.Id),
                settings.Name,
                Normalize(GetString(error, "message"), "Provider command failed."));
        }

        var usage = TryGetObject(payload, "usage", out var usageElement) ? usageElement : default;
        var credits = TryGetObject(payload, "credits", out var creditsElement) ? creditsElement : default;
        var window = usage.ValueKind == JsonValueKind.Object && TryGetObject(usage, "primary", out var primary)
            ? primary
            : default;
        var status = TryGetObject(payload, "status", out var statusElement) ? statusElement : default;

        var remaining = WindowRemainingPercent(window);
        var resetsAt = GetDate(window, "resetsAt");
        var updatedAt = GetDate(usage, "updatedAt") ?? GetDate(credits, "updatedAt");
        var source = GetString(payload, "source");
        var account = GetString(payload, "account");
        var detail = JoinDetail(
            account is null ? null : $"account: {account}",
            source is null ? null : $"source: {source}",
            GetString(status, "description"),
            GetString(window, "resetDescription"));

        if (remaining is not null)
        {
            return new ProviderSnapshot(
                Normalize(GetString(payload, "provider"), settings.Id),
                settings.Name,
                ParseStatusHealth(GetString(status, "indicator")),
                WindowLabel(GetDouble(window, "windowMinutes")),
                remaining,
                Limit: 100,
                Unit: "% left",
                ResetsAt: resetsAt,
                UpdatedAt: updatedAt ?? DateTimeOffset.UtcNow,
                Detail: detail,
                SourceUrl: GetString(status, "url"));
        }

        var creditRemaining = GetDouble(credits, "remaining");
        return new ProviderSnapshot(
            Normalize(GetString(payload, "provider"), settings.Id),
            settings.Name,
            ParseStatusHealth(GetString(status, "indicator")),
            Window: creditRemaining is null ? null : "credits",
            Remaining: creditRemaining,
            Limit: null,
            Unit: creditRemaining is null ? null : "credits left",
            ResetsAt: resetsAt,
            UpdatedAt: updatedAt ?? DateTimeOffset.UtcNow,
            Detail: detail ?? "CodexBar CLI payload did not include usage limits.",
            SourceUrl: GetString(status, "url"));
    }

    private static JsonElement SelectCliPayload(JsonElement payloads, ProviderProbeSettings settings)
    {
        JsonElement? first = null;
        foreach (var payload in payloads.EnumerateArray())
        {
            if (payload.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            first ??= payload;
            var provider = GetString(payload, "provider");
            if (MatchesProvider(provider, settings))
            {
                return payload;
            }
        }

        return first ?? throw new InvalidOperationException("CodexBar CLI JSON payload was empty.");
    }

    private static bool MatchesProvider(string? provider, ProviderProbeSettings settings)
    {
        return string.Equals(provider, settings.Id, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(provider, settings.Name, StringComparison.OrdinalIgnoreCase);
    }

    private static double? WindowRemainingPercent(JsonElement window)
    {
        var usedPercent = GetDouble(window, "usedPercent");
        if (usedPercent is null)
        {
            return null;
        }

        return Math.Clamp(100 - usedPercent.Value, 0, 100);
    }

    private static string WindowLabel(double? windowMinutes)
    {
        return windowMinutes switch
        {
            300 => "session",
            1440 => "daily",
            10080 => "weekly",
            43200 => "monthly",
            null => "session",
            _ => $"{windowMinutes:0}m",
        };
    }

    private static ProviderHealth ParseStatusHealth(string? value)
    {
        return value?.Trim().ToLowerInvariant() switch
        {
            "none" => ProviderHealth.Healthy,
            "minor" or "maintenance" => ProviderHealth.Warning,
            "major" or "critical" => ProviderHealth.Failing,
            _ => ProviderHealth.Unknown,
        };
    }

    private static bool TryGetObject(JsonElement element, string propertyName, out JsonElement value)
    {
        if (TryGetProperty(element, propertyName, out value) && value.ValueKind == JsonValueKind.Object)
        {
            return true;
        }

        value = default;
        return false;
    }

    private static bool TryGetProperty(JsonElement element, string propertyName, out JsonElement value)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (string.Equals(property.Name, propertyName, StringComparison.OrdinalIgnoreCase))
                {
                    value = property.Value;
                    return true;
                }
            }
        }

        value = default;
        return false;
    }

    private static string? GetString(JsonElement element, string propertyName)
    {
        if (!TryGetProperty(element, propertyName, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.String => NormalizeOptional(value.GetString()),
            JsonValueKind.Number => value.GetRawText(),
            _ => null,
        };
    }

    private static double? GetDouble(JsonElement element, string propertyName)
    {
        return TryGetProperty(element, propertyName, out var value) &&
            value.ValueKind == JsonValueKind.Number &&
            value.TryGetDouble(out var number)
                ? number
                : null;
    }

    private static DateTimeOffset? GetDate(JsonElement element, string propertyName)
    {
        if (!TryGetProperty(element, propertyName, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(value.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var date))
        {
            return date;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var seconds))
        {
            return DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000));
        }

        return null;
    }

    private static string? JoinDetail(params string?[] parts)
    {
        var detail = string.Join("; ", parts.Where(part => !string.IsNullOrWhiteSpace(part)));
        return string.IsNullOrWhiteSpace(detail) ? null : detail;
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
