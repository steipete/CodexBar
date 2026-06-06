using CodexBar.Windows.Core;

namespace CodexBar.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(initiallyOwned: true, "CodexBar.Windows.Tray", out var ownsMutex);
        if (!ownsMutex)
        {
            return;
        }

        ApplicationConfiguration.Initialize();

        var settings = WindowsSettingsStore.LoadOrCreate();
        using var context = new CodexBarTrayContext(settings, new ProviderProbeRunner());
        Application.Run(context);
    }
}
