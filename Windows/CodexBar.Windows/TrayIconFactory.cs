using System.Drawing;
using System.Runtime.InteropServices;
using CodexBar.Windows.Core;

namespace CodexBar.Windows;

internal static class TrayIconFactory
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    public static Icon Create(ProviderHealth health)
    {
        var fill = health switch
        {
            ProviderHealth.Healthy => Color.FromArgb(22, 163, 74),
            ProviderHealth.Busy => Color.FromArgb(37, 99, 235),
            ProviderHealth.Warning => Color.FromArgb(217, 119, 6),
            ProviderHealth.Failing => Color.FromArgb(220, 38, 38),
            _ => Color.FromArgb(82, 82, 91),
        };

        using var bitmap = new Bitmap(32, 32);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

        using var background = new SolidBrush(fill);
        FillRoundedRectangle(graphics, background, new Rectangle(2, 2, 28, 28), 7);

        using var font = new Font("Segoe UI", 15, FontStyle.Bold, GraphicsUnit.Pixel);
        using var textBrush = new SolidBrush(Color.White);
        var textSize = graphics.MeasureString("CB", font);
        graphics.DrawString("CB", font, textBrush, (32 - textSize.Width) / 2, (31 - textSize.Height) / 2);

        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    private static void FillRoundedRectangle(Graphics graphics, Brush brush, Rectangle bounds, int radius)
    {
        using var path = new System.Drawing.Drawing2D.GraphicsPath();
        var diameter = radius * 2;
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        graphics.FillPath(brush, path);
    }
}
