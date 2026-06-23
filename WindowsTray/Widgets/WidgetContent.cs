using System.ComponentModel;

namespace CodexBarTray;

/// <summary>The kind of content a desktop widget renders.</summary>
public enum WidgetKind
{
    Usage = 0,       // a provider's rate-limit windows
    Cost = 1,        // compact session / today / 30-day cost
    CostHistory = 2, // mini bar chart of daily cost
}

/// <summary>The latest data pushed into widgets on each refresh.</summary>
public sealed record WidgetData(
    IReadOnlyList<ProviderViewModel> Usage,
    IReadOnlyList<CostResult> Cost)
{
    public static readonly WidgetData Empty =
        new(Array.Empty<ProviderViewModel>(), Array.Empty<CostResult>());
}

/// <summary>
/// Base for a widget's bindable content. Each kind subclasses this; the window
/// binds its header to <see cref="Title"/> and its body to the concrete type via
/// implicit DataTemplates. <see cref="Update"/> is called on every refresh.
/// </summary>
public abstract class WidgetContentViewModel : INotifyPropertyChanged
{
    public string ProviderId { get; }
    protected string FallbackName { get; }

    protected WidgetContentViewModel(string providerId, string fallbackName)
    {
        ProviderId = providerId;
        FallbackName = fallbackName;
    }

    public abstract string Title { get; }
    public abstract void Update(WidgetData data);

    protected bool MatchesProvider(string id) =>
        string.Equals(id, ProviderId, StringComparison.OrdinalIgnoreCase);

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Signal that every bound property may have changed (empty name).</summary>
    protected void RaiseAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
}
