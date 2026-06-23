namespace CodexBarTray;

/// <summary>Content for a Usage widget: one provider's rate-limit windows.</summary>
public sealed class UsageWidgetViewModel : WidgetContentViewModel
{
    private ProviderViewModel? _provider;

    public UsageWidgetViewModel(string providerId, string fallbackName)
        : base(providerId, fallbackName) { }

    public ProviderViewModel? Provider => _provider;
    public bool NoData => _provider is null;
    public override string Title =>
        _provider?.Name is { Length: > 0 } name ? name : FallbackName;

    public override void Update(WidgetData data)
    {
        _provider = data.Usage.FirstOrDefault(p => MatchesProvider(p.Id));
        RaiseAll();
    }
}
