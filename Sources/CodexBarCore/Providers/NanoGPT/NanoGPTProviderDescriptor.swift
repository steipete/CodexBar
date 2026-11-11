import Foundation

/// NanoGPT is pay-as-you-go and subscription billing through one key. The provider reads subscription token
/// quotas, prepaid USD balance, and month-to-date spend from NanoGPT's documented read-only endpoints
/// on the direct API host.
public enum NanoGPTProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor(
        credentials: ProviderCredentialAdapter.apiKey(
            environmentKey: NanoGPTSettingsReader.apiKeyEnvironmentKey,
            apiKeyDebugLabel: NanoGPTSettingsReader.apiKeyDebugLabel,
            resolve: NanoGPTSettingsReader.apiKey,
            tokenAccountSupport: Self.tokenAccounts,
            missingCredentialMessage: { _ in Self.missingCredentialMessage }),
        fetchPlan: Self.fetchPlan())

    public static let spec = PluginProviderSpec(
        id: .nanogpt,
        displayName: "NanoGPT",
        sessionLabel: "Daily input tokens",
        weeklyLabel: "Weekly input tokens",
        dashboardURL: "https://nano-gpt.com/usage",
        color: .init(hex: 0x16A34A),
        confetti: [0x16A34A, 0x86EFAC, 0xFFFFFF],
        noDataMessage: "NanoGPT per-request cost history is not available.",
        environmentKey: NanoGPTSettingsReader.apiKeyEnvironmentKey,
        apiKeyDebugLabel: NanoGPTSettingsReader.apiKeyDebugLabel,
        missingCredentialMessage: { _ in Self.missingCredentialMessage },
        tokenAccountSupport: Self.tokenAccounts,
        // Automatic menu bar text shows the prepaid dollar balance. Daily and weekly selections stay
        // available when one lane is unconfigured, for example a token quota with no image quota.
        menuBarMetrics: .init(supported: [.automatic, .primary, .secondary]),
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in
                // Subscription quotas and prepaid credits are separate. The card always shows the dollar
                // balance; a generic style would hide it when there is no monthly cap.
                ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .payAsYouGoSpend)
            },
            menuBarBalanceUsesPrepaidCost: true,
            menuCard: ProviderMenuCardPresentation(providerCostIsRequiredUsage: true)),
        // The script waits on each call in order. Both GETs may time out and retry once (8+1+8 and 7+1+7),
        // and the balance POST may try the API host and then the website (5+4). 45 seconds covers that path.
        timeout: 45,
        apiKeyField: .init(
            id: "nanogpt-api-key",
            title: "NanoGPT API key",
            subtitle: "Saved in CodexBar's local config file. Or set NANOGPT_API_KEY. Read-only usage access.",
            action: ("nanogpt-dashboard", "Open NanoGPT", "https://nano-gpt.com/usage")),
        availability: .configuredKey)

    static let missingCredentialMessage = "Paste a NanoGPT API key in Settings or set NANOGPT_API_KEY."

    static let tokenAccounts = TokenAccountSupport(
        title: "API tokens",
        subtitle: "Store multiple NanoGPT inference keys.",
        placeholder: "Paste NanoGPT API key…",
        injection: .environment(key: NanoGPTSettingsReader.apiKeyEnvironmentKey),
        requiresManualCookieSource: false,
        cookieName: nil)

    /// Both sources run the same script. The host derives API availability from the key, so the plan only
    /// needs to declare the allowed source modes and the single strategy instance.
    private static func fetchPlan() -> ProviderFetchPlan {
        let strategy = Self.spec.makeStrategy()
        return ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [strategy] }))
    }
}
