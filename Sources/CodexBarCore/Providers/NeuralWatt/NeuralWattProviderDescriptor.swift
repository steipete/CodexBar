import Foundation

public enum NeuralWattProviderDescriptor {
    private static let missingCredentialMessage =
        "Missing Neuralwatt API key. Set apiKey in the CodexBar config file or NEURALWATT_API_KEY."
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .neuralwatt,
        displayName: "Neuralwatt",
        sessionLabel: "Subscription",
        weeklyLabel: "Key allowance",
        creditsHint: "Subscription kWh and prepaid USD balance.",
        usesDetailBackedWindow: true,
        dashboardURL: "https://portal.neuralwatt.com/dashboard",
        subscriptionDashboardURL: "https://portal.neuralwatt.com/dashboard",
        color: ProviderColor(red: 0.22, green: 0.85, blue: 0.55),
        confetti: [0x38D98C, 0x17243A, 0xFFFFFF],
        widgetColor: ProviderColor(hex: 0x38D98C),
        noDataMessage: "Neuralwatt token cost history is not available via the quota API.",
        environmentKey: NeuralWattSettingsReader.apiKeyEnvironmentKey,
        missingCredentialMessage: { _ in NeuralWattProviderDescriptor.missingCredentialMessage },
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple Neuralwatt API keys.",
            placeholder: "sk-...",
            injection: .environment(key: NeuralWattSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            minimumDelayBetweenAccountRefreshes: .seconds(1)),
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .payAsYouGoBalance) },
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                hidesPrimaryResetWithoutDate: true),
            menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
        aliases: ["nw", "neural"],
        timeout: 45,
        scriptSettings: { ["BASE_URL": NeuralWattSettingsReader.apiURL(environment: $0.env).absoluteString] },
        validateContext: { context in
            guard NeuralWattSettingsReader.apiKey(environment: context.env) != nil else {
                throw ProviderFetchClassifiedError(kind: .missingCredential, message: Self.missingCredentialMessage)
            }
            try NeuralWattSettingsReader.validateEndpointOverrides(environment: context.env)
        },
        apiKeyField: .init(
            id: "neuralwatt-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file. Manage keys from the Neuralwatt dashboard.",
            placeholder: "sk-..."),
        showsAPIDetail: true,
        availability: .configuredKeyOrAccount,
        observesTokenAccounts: true)
}
