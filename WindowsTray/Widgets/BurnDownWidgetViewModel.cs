namespace CodexBarTray;

/// <summary>
/// Content for a Burn-Down widget: the session or weekly window's burn-down
/// projection for one provider, computed live from the latest /usage window.
/// </summary>
public sealed class BurnDownWidgetViewModel : WidgetContentViewModel
{
    private readonly QuotaWindowKind _window;
    private BurnGeom? _geom;

    public BurnDownWidgetViewModel(string providerId, string fallbackName, QuotaWindowKind window)
        : base(providerId, fallbackName)
    {
        _window = window;
    }

    public override string Title =>
        $"{FallbackName} · {(_window == QuotaWindowKind.Session ? "session" : "weekly")} burn-down";

    public BurnGeom? Geom => _geom;
    public bool HasData => _geom is not null;
    public bool NoData => !HasData;
    public string EmptyText => "No window data";

    public string RemainingText => _geom is { } g ? $"{Math.Round(g.VNow)}% left" : "";

    public string StatusText => _geom?.Status switch
    {
        BurnStatus.Ahead => "Ahead of pace",
        BurnStatus.Behind => "Behind pace",
        BurnStatus.OnPace => "On pace",
        _ => "",
    };

    public string ProjectionText
    {
        get
        {
            if (_geom is not { } g) return "";
            if (g.VNow <= 0.5) return "Depleted";
            if (g.RunsOut && g.MinutesToEmpty is { } mins) return $"Empties in {FormatDuration(mins)}";
            return "On track to reset";
        }
    }

    public override void Update(WidgetData data)
    {
        var result = data.Raw.FirstOrDefault(r => MatchesProvider(r.Provider));
        var window = _window == QuotaWindowKind.Session
            ? result?.Usage?.Primary
            : result?.Usage?.Secondary;
        _geom = BurnGeom.From(window, DateTimeOffset.Now);
        RaiseAll();
    }

    private static string FormatDuration(double minutes)
    {
        if (!double.IsFinite(minutes) || minutes <= 0) return "—";
        if (minutes >= 1440)
        {
            var days = (int)(minutes / 1440);
            var hours = (int)(minutes / 60) % 24;
            return $"{days}d {hours}h";
        }
        var h = (int)(minutes / 60);
        var m = (int)minutes % 60;
        return h <= 0 ? $"{Math.Max(1, m)}m" : $"{h}h {m:D2}m";
    }
}
