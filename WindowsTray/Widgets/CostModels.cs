using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexBarTray;

// DTOs matching the `codexbar serve` /cost JSON (an array of per-provider cost
// results). Only Claude and Codex are cost-supported. Unknown fields ignored.

public sealed class CostResult
{
    [JsonPropertyName("provider")] public string Provider { get; set; } = "";
    [JsonPropertyName("source")] public string? Source { get; set; }
    [JsonPropertyName("currencyCode")] public string? CurrencyCode { get; set; }
    [JsonPropertyName("sessionCostUSD")] public double? SessionCostUSD { get; set; }
    [JsonPropertyName("last30DaysCostUSD")] public double? Last30DaysCostUSD { get; set; }
    [JsonPropertyName("historyDays")] public int? HistoryDays { get; set; }
    [JsonPropertyName("daily")] public List<CostDailyEntry>? Daily { get; set; }
    [JsonPropertyName("error")] public ProviderError? Error { get; set; }
}

public sealed class CostDailyEntry
{
    [JsonPropertyName("date")] public string Date { get; set; } = "";
    // Serialized as "totalCost" by the CLI (CostDailyEntryPayload.CodingKeys).
    [JsonPropertyName("totalCost")] public double? TotalCost { get; set; }
    [JsonPropertyName("totalTokens")] public long? TotalTokens { get; set; }
}

public static class CostJson
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public static List<CostResult> Parse(string json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new List<CostResult>();
        try
        {
            return JsonSerializer.Deserialize<List<CostResult>>(json, Options) ?? new List<CostResult>();
        }
        catch
        {
            // /cost returns an object ({"error": ...}) on bad requests rather than an array.
            return new List<CostResult>();
        }
    }
}

/// <summary>Formats a USD-or-other amount for the compact cost widgets.</summary>
public static class Money
{
    public static string Format(double? amount, string? currencyCode)
    {
        if (amount is not { } value) return "—";
        var code = string.IsNullOrWhiteSpace(currencyCode) ? "USD" : currencyCode.ToUpperInvariant();
        var text = value.ToString(value >= 100 ? "N0" : "N2");
        return code == "USD" ? $"${text}" : $"{text} {code}";
    }
}
