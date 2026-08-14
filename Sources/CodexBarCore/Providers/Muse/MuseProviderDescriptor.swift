import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: MuseSettingsReader.apiKeyEnvironmentKeys[0],
        precedence: .environment,
        environmentHasValue: { MuseSettingsReader.apiKey(environment: $0) != nil },
        resolve: { env in MuseSettingsReader.apiKey(environment: env) },
        missingCredentialMessage: { _ in MuseUsageError.missingCredentials.errorDescription ?? "Missing Muse API key" }
    )

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            settingsSection: .init(MuseProviderSettingsKey.self, credentialSettings: { context in
                MuseProviderSettings(baseURL: context.config?.sanitizedBaseURL)
            }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Muse",
                shortDisplayName: "Muse",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Muse (Meta) usage",
                cliName: "muse",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                browserCookieOrder: nil,
                dashboardURL: "https://ai.developer.meta.com/",
                statusPageURL: nil,
                statusLinkURL: nil
            ),
            branding: ProviderBranding(
                iconStyle: .init(provider: .muse),
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 0.0 / 255, green: 100 / 255, blue: 224 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0064E0),
                    ProviderColor(hex: 0x0469FF),
                    ProviderColor(hex: 0x7B61FF),
                ],
                widgetColor: ProviderColor(red: 0.0 / 255, green: 100 / 255, blue: 224 / 255)
            ),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Muse cost history is not available via API. Billing is pay-as-you-go at $1.25 / $4.25 per 1M tokens." }
            ),
            presentation: ProviderUsagePresentation(
                planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)
            ),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MuseAPIFetchStrategy()] })
            ),
            cli: ProviderCLIConfig(
                name: "muse",
                aliases: ["meta", "metamuse"],
                versionDetector: nil
            )
        )
    }
}

struct MuseAPIFetchStrategy: ProviderFetchStrategy {
    let id = "muse.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        MuseSettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = MuseSettingsReader.apiKey(environment: context.env) else {
            throw MuseUsageError.missingCredentials
        }

        // Prefer config baseURL (via settings), then env, then default
        let baseURL: String? = context.settings?.muse?.baseURL ?? MuseSettingsReader.baseURL(environment: context.env)

        let usage = try await MuseUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURLString: baseURL,
            session: self.transport
        )
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

// MARK: - ProviderConfig extension for baseURL

extension ProviderConfig {
    public var baseURL: String? {
        get { self.extensionValue(forKey: "baseURL") }
        set { self.setExtensionValue(newValue, forKey: "baseURL") }
    }

    public var sanitizedBaseURL: String? {
        Self.clean(self.baseURL)
    }
}
