namespace CodexBarTray;

public enum BurnStatus { Ahead, OnPace, Behind }

/// <summary>
/// Burn-down projection geometry for one rate window, ported from the macOS
/// widget's BurnGeom (Sources/CodexBarWidget/BurnDownWidgetViews.swift). Pure
/// projection — no historical samples: the "actual" line runs straight from 100%
/// at window start to the current point, with an ideal diagonal and a run-out
/// projection derived from the current pace.
/// </summary>
public sealed class BurnGeom
{
    public double VNow { get; }     // % remaining (0..100)
    public double TNow { get; }     // position in window (0..1)
    public double IdealNow { get; } // what you should have left = 100 * (1 - tNow)
    public double Margin { get; }   // vNow - idealNow; + = conserving, − = over pace
    public double Slope { get; }    // %/unit-t (negative = burning)
    public double ProjT { get; }    // t where the projection ends
    public double ProjV { get; }    // v where the projection ends
    public bool RunsOut { get; }    // projection hits 0 inside the window
    public int? WindowMinutes { get; }

    public BurnStatus Status => Margin > 4 ? BurnStatus.Ahead : Margin < -4 ? BurnStatus.Behind : BurnStatus.OnPace;

    /// <summary>Minutes until the projection reaches 0, or null if not burning down.</summary>
    public double? MinutesToEmpty =>
        Slope < -0.01 && WindowMinutes is { } mins ? (VNow / -Slope) * mins : null;

    private BurnGeom(double vNow, double tNow, double slope, double projT, double projV, bool runsOut, int? windowMinutes)
    {
        VNow = vNow;
        TNow = tNow;
        IdealNow = 100.0 * (1.0 - tNow);
        Margin = vNow - IdealNow;
        Slope = slope;
        ProjT = projT;
        ProjV = projV;
        RunsOut = runsOut;
        WindowMinutes = windowMinutes;
    }

    public static BurnGeom? From(RateWindow? window, DateTimeOffset now)
    {
        if (window is null) return null;

        var remaining = Math.Clamp(100.0 - window.UsedPercent, 0, 100);

        double t;
        if (window.ResetsAt is { } resetsAt && window.WindowMinutes is { } windowMins && windowMins > 0)
        {
            var minutesUntilReset = Math.Max(0, (resetsAt - now).TotalMinutes);
            var minutesElapsed = windowMins - minutesUntilReset;
            t = Math.Clamp(minutesElapsed / windowMins, 0.001, 0.999);
        }
        else
        {
            t = Math.Clamp(window.UsedPercent / 100.0, 0.001, 0.999);
        }

        var slope = t > 0.001 ? (remaining - 100.0) / t : -remaining;

        double projT, projV;
        bool runsOut;
        if (slope < -0.01)
        {
            var tOut = t + remaining / -slope;
            if (tOut <= 1.0)
            {
                projT = tOut;
                projV = 0;
                runsOut = true;
            }
            else
            {
                projT = 1.0;
                projV = Math.Max(0, remaining + slope * (1.0 - t));
                runsOut = false;
            }
        }
        else
        {
            projT = 1.0;
            projV = remaining;
            runsOut = false;
        }

        return new BurnGeom(remaining, t, slope, projT, projV, runsOut, window.WindowMinutes);
    }
}
