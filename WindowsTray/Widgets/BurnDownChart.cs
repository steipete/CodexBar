using System.Windows;
using System.Windows.Media;

namespace CodexBarTray;

/// <summary>
/// Draws a burn-down projection chart for a <see cref="BurnGeom"/>: a "now"
/// hairline, baseline, area fill under the actual line, a dashed ideal diagonal,
/// a dotted run-out projection, the solid actual line, and the now dot. Mirrors
/// the macOS widget's BurnChartCanvas draw order and coordinate mapping.
/// </summary>
public sealed class BurnDownChart : FrameworkElement
{
    public static readonly DependencyProperty GeomProperty = DependencyProperty.Register(
        nameof(Geom), typeof(BurnGeom), typeof(BurnDownChart),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public BurnGeom? Geom
    {
        get => (BurnGeom?)GetValue(GeomProperty);
        set => SetValue(GeomProperty, value);
    }

    // Palette aligned with the panel's usage colors.
    private static readonly Color Teal = Color.FromRgb(0x16, 0xD3, 0xB4);
    private static readonly Color Amber = Color.FromRgb(0xE5, 0xA5, 0x0A);
    private static readonly Color Red = Color.FromRgb(0xE0, 0x48, 0x3B);
    private static readonly Brush Grid = Frozen(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));
    private static readonly Brush Ideal = Frozen(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF));

    protected override void OnRender(DrawingContext dc)
    {
        if (Geom is not { } geom) return;

        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        const double padT = 8, padB = 2, padL = 1, padR = 1;
        double X(double t) => padL + t * (w - padL - padR);
        double Y(double v) => padT + (1 - v / 100) * (h - padT - padB);

        var tNow = geom.TNow;
        var vNow = geom.VNow;
        var accent = AccentColor(geom.Status);
        var accentBrush = Frozen(accent);

        // Now vertical hairline + baseline.
        var gridPen = new Pen(Grid, 1);
        dc.DrawLine(gridPen, new Point(X(tNow), Y(100)), new Point(X(tNow), Y(0)));
        dc.DrawLine(gridPen, new Point(X(0), Y(0)), new Point(X(1), Y(0)));

        // Area fill (actual line down to baseline).
        var fill = new StreamGeometry();
        using (var ctx = fill.Open())
        {
            ctx.BeginFigure(new Point(X(0), Y(100)), isFilled: true, isClosed: true);
            ctx.LineTo(new Point(X(tNow), Y(vNow)), true, false);
            ctx.LineTo(new Point(X(tNow), Y(0)), true, false);
            ctx.LineTo(new Point(X(0), Y(0)), true, false);
        }
        fill.Freeze();
        var gradient = new LinearGradientBrush(
            Color.FromArgb(0x3A, accent.R, accent.G, accent.B),
            Color.FromArgb(0x00, accent.R, accent.G, accent.B),
            new Point(0, 0), new Point(0, 1));
        gradient.Freeze();
        dc.DrawGeometry(gradient, null, fill);

        // Ideal diagonal (dashed).
        var idealPen = new Pen(Ideal, 1.4) { DashStyle = new DashStyle(new double[] { 2.5, 3 }, 0), DashCap = PenLineCap.Round };
        dc.DrawLine(idealPen, new Point(X(0), Y(100)), new Point(X(1), Y(0)));

        // Run-out projection (fine dotted) when actively burning.
        if (geom.Slope < -0.01)
        {
            var projPen = new Pen(accentBrush, 1.6) { DashStyle = new DashStyle(new double[] { 0.5, 3.5 }, 0), DashCap = PenLineCap.Round };
            dc.DrawLine(projPen, new Point(X(tNow), Y(vNow)), new Point(X(geom.ProjT), Y(geom.ProjV)));
        }

        // Actual line (solid hero) from full at start to now.
        var linePen = new Pen(accentBrush, 2.4) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        dc.DrawLine(linePen, new Point(X(0), Y(100)), new Point(X(tNow), Y(vNow)));

        // Now dot.
        var center = new Point(X(tNow), Y(vNow));
        dc.DrawEllipse(Frozen(Color.FromRgb(0x15, 0x15, 0x1A)), null, center, 5.4, 5.4);
        dc.DrawEllipse(accentBrush, null, center, 3.4, 3.4);
    }

    private static Color AccentColor(BurnStatus status) => status switch
    {
        BurnStatus.Ahead => Teal,
        BurnStatus.Behind => Red,
        _ => Amber,
    };

    private static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
