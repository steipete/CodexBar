namespace CodexBarTray;

/// <summary>Content for a Cost widget: compact session / today / 30-day spend.</summary>
public sealed class CostWidgetViewModel : WidgetContentViewModel
{
    private CostResult? _cost;

    public CostWidgetViewModel(string providerId, string fallbackName)
        : base(providerId, fallbackName) { }

    public override string Title => $"{FallbackName} · cost";

    public bool HasData => _cost is not null && _cost.Error is null;
    public bool NoData => !HasData;
    public string EmptyText => _cost?.Error?.Message ?? "No cost data";

    public string SessionText => Money.Format(_cost?.SessionCostUSD, _cost?.CurrencyCode);
    public string TodayText => Money.Format(TodayCost(), _cost?.CurrencyCode);
    public string MonthText => Money.Format(_cost?.Last30DaysCostUSD, _cost?.CurrencyCode);

    public override void Update(WidgetData data)
    {
        _cost = data.Cost.FirstOrDefault(c => MatchesProvider(c.Provider));
        RaiseAll();
    }

    private double? TodayCost()
    {
        if (_cost?.Daily is not { Count: > 0 } daily) return null;
        var today = DateTime.Now.ToString("yyyy-MM-dd");
        var match = daily.FirstOrDefault(d => d.Date == today);
        // No spend recorded today yet still means $0, not "unknown".
        return match?.TotalCost ?? 0;
    }
}
