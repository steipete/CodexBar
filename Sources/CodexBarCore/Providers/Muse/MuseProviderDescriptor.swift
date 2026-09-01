import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: MuseSettingsReader.apiKeyEnvironmentKeys[0],
        environmentHasValue: { MuseSettingsReader.apiKey(environment: $0) != nil },
        resolve: MuseSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple Muse API keys (META_API_KEY).",
            placeholder: "Paste META_API_KEY…",
            injection: .environment(key: MuseSettingsReader.apiKeyEnvironmentKeys[0]),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in MuseUsageError.missingCredentials.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Muse",
                shortDisplayName: "Muse",
                sessionLabel: "Tokens",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Muse usage",
                cliName: "muse",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [:],
                dashboardURL: "https://dev.meta.ai",
                subscriptionDashboardURL: "https://dev.meta.ai/docs/pricing-rate-limits",
                changelogURL: "https://dev.meta.ai/docs/muse-code/changelog",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .muse),
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 6 / 255, green: 104 / 255, blue: 225 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0668E1),
                    ProviderColor(hex: 0x00AEFF),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                burnDownWidgetColor: ProviderColor(red: 6 / 255, green: 104 / 255, blue: 225 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Muse does not publish a cost endpoint. Set META_API_KEY or run `muse login`." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "muse",
                aliases: ["muse-code"],
                binaryLocator: nil,
                versionDetector: nil,
                supportsCostCommand: false))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api, .cli],
            pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        let hasKey = MuseSettingsReader.apiKey(environment: context.env) != nil

        switch context.sourceMode {
        case .api:
            return [MuseAPIFetchStrategy()]
        case .cli:
            return [MuseLocalFetchStrategy()]
        case .auto:
            // Only the API key can produce quota; the local login supplies identity when it cannot.
            if hasKey {
                return [MuseAPIFetchStrategy(), MuseLocalFetchStrategy()]
            }
            if MuseLocalAuthReader.read() != nil {
                return [MuseLocalFetchStrategy()]
            }
            // No credentials anywhere: keep the API strategy so the miss surfaces as a friendly error.
            return [MuseAPIFetchStrategy()]
        case .web, .oauth:
            return []
        }
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
        // Always available so a missing key surfaces as an actionable error rather than an empty menu.
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = MuseSettingsReader.apiKey(environment: context.env) else {
            throw MuseUsageError.missingCredentials
        }
        let localAuth = MuseLocalAuthReader.read()
        let baseURL = try MuseSettingsReader.baseURL(environment: context.env, localAuth: localAuth)
        let snapshot = try await MuseUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURL: baseURL,
            localAuth: localAuth,
            transport: self.transport)
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "api")
    }

    /// Fall back to the local identity only when the key itself is the problem; a network or endpoint
    /// failure must stay visible instead of being papered over with an identity card.
    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        guard let error = error as? MuseUsageError else { return false }
        switch error {
        case .missingCredentials, .invalidAPIKey:
            return MuseLocalAuthReader.read() != nil
        case .invalidEndpointOverride, .usageUnavailable, .networkError:
            return false
        }
    }
}

/// Identity from the credential metadata `muse login` writes to `~/.config/muse/auth.json`.
///
/// Muse exposes no non-interactive auth-status command (`muse auth` only offers `auth set`), so login
/// state is read from that file rather than inferred from a CLI exit code. Reporting quota is not
/// possible here: the rate-limit headers only accompany an authenticated API call.
struct MuseLocalFetchStrategy: ProviderFetchStrategy {
    let id = "muse.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        MuseLocalAuthReader.read() != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let localAuth = MuseLocalAuthReader.read() else {
            throw MuseUsageError.missingCredentials
        }
        let snapshot = MuseUsageSnapshot(
            accountEmail: localAuth.accountEmail,
            plan: localAuth.loginMethod,
            updatedAt: Date())
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "local",
            diagnostic: "Muse reports quota only through API rate-limit headers; set META_API_KEY for usage.")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
