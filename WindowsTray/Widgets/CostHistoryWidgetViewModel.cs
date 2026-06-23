using System.Windows.Media;

namespace CodexBarTray;

/// <summary>One bar in the cost-history mini chart.</summary>
public sealed class CostBar
{
    public double Height { get; init; }
    public string Tooltip { get; init; } = "";
    public Brush Fill { get; init; } = Brushes.Gray;
}

/// <summary>Content for a Cost History widget: a mini bar chart of daily spend.</summary>
public sealed class CostHistoryWidgetViewModel : WidgetContentViewModel
{
    private const int MaxBars = 14;
    private const double ChartHeight = 44;
    private const double MinBarHeight = 2;

    private static readonly Brush BarBrush = Freeze(Color.FromRgb(0x16, 0xD3, 0xB4));

    private CostResult? _cost;
    private List<CostBar> _bars = new();

    public CostHistoryWidgetViewModel(string providerId, string fallbackName)
        : base(providerId, fallbackName) { }

    public override string Title => $"{FallbackName} · cost history";

    public IReadOnlyList<CostBar> Bars => _bars;
    public bool HasData => _bars.Count > 0;
    public bool NoData => !HasData;
    public string EmptyText => _cost?.Error?.Message ?? "No cost data";
    public string Caption => _cost?.HistoryDays is { } days && days > 0
        ? $"Daily cost · last {Math.Min(days, MaxBars)} days"
        : "Daily cost";

    public override void Update(WidgetData data)
    {
        _cost = data.Cost.FirstOrDefault(c => MatchesProvider(c.Provider));
        _bars = BuildBars(_cost);
        RaiseAll();
    }

    private static List<CostBar> BuildBars(CostResult? cost)
    {
        if (cost?.Error is not null || cost?.Daily is not { Count: > 0 } daily)
            return new List<CostBar>();

        var recent = daily
            .OrderBy(d => d.Date, StringComparer.Ordinal) // ISO dates sort chronologically
            .TakeLast(MaxBars)
            .ToList();

        var max = recent.Max(d => d.TotalCost ?? 0);
        var bars = new List<CostBar>(recent.Count);
        foreach (var entry in recent)
        {
            var value = entry.TotalCost ?? 0;
            var height = max > 0 ? MinBarHeight + (ChartHeight - MinBarHeight) * (value / max) : MinBarHeight;
            bars.Add(new CostBar
            {
                Height = height,
                Tooltip = $"{entry.Date}: {Money.Format(value, cost.CurrencyCode)}",
                Fill = BarBrush,
            });
        }
        return bars;
    }

    private static Brush Freeze(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
