import Foundation

public enum FactoryProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .factory,
            metadata: ProviderMetadata(
                id: .factory,
                displayName: "Droid",
                sessionLabel: "Standard",
                weeklyLabel: "Premium",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Droid usage",
                cliName: "factory",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://app.factory.ai/settings/billing",
                statusPageURL: "https://status.factory.ai",
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .factory,
                iconResourceName: "ProviderIcon-factory",
                color: ProviderColor(red: 255 / 255, green: 107 / 255, blue: 53 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xEE6018),
                    ProviderColor(hex: 0xA0CA92),
                    ProviderColor(hex: 0x1D1A18),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Droid cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                // `.cli` remains as an Auto compatibility alias for persisted configs from older builds
                // that advertised `[.auto, .cli]` while only implementing the web strategy.
                sourceModes: [.auto, .api, .web, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "factory",
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .api:
            [FactoryAPIFetchStrategy()]
        case .web:
            [FactoryStatusFetchStrategy()]
        case .auto, .cli:
            // Legacy `source: cli` behaves as Auto (API key first, then cookies/WorkOS on macOS).
            // Recoverable API failures fall through to web; explicit `.api` does not.
            [FactoryAPIFetchStrategy(), FactoryStatusFetchStrategy()]
        case .oauth:
            []
        }
    }
}

struct FactoryAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "factory.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Explicit API mode always runs so a missing key surfaces as FactoryStatusProbeError.missingAPIKey.
        // Auto mode only tries API when a key is resolvable, then falls back to cookies/WorkOS
        // for missing/unauthorized keys and other recoverable API failures.
        context.sourceMode == .api || Self.resolveAPIKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveAPIKey(environment: context.env) else {
            throw FactoryStatusProbeError.missingAPIKey
        }

        let probe = FactoryStatusProbe(browserDetection: context.browserDetection)
        do {
            let snap = try await probe.fetch(apiKey: apiKey)
            return self.makeResult(
                usage: snap.toUsageSnapshot(),
                sourceLabel: "api")
        } catch let error as FactoryStatusProbeError {
            throw Self.mapAPIError(error)
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        // Explicit API mode stays strict. Auto/cli keep cookies/WorkOS as a recoverable fallback so
        // timeouts, DNS/5xx failures, and parse changes do not strand existing web setups.
        guard context.sourceMode == .auto || context.sourceMode == .cli else { return false }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return false
        }
        return true
    }

    private static func resolveAPIKey(environment: [String: String]) -> String? {
        FactorySettingsReader.apiKey(environment: environment)
    }

    private static func mapAPIError(_ error: FactoryStatusProbeError) -> FactoryStatusProbeError {
        switch error {
        case .notLoggedIn:
            .unauthorizedAPIKey
        case let .networkError(message)
            where message.contains("HTTP 401") || message.contains("HTTP 403"):
            .unauthorizedAPIKey
        default:
            error
        }
    }
}

struct FactoryStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "factory.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        #if !os(macOS)
        // Cookie/WorkOS import is macOS-only; Linux relies on API-key auth instead.
        return false
        #else
        guard context.settings?.factory?.cookieSource != .off else { return false }
        return true
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = FactoryStatusProbe(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let snap = try await probe.fetch(cookieHeaderOverride: manual)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.factory?.cookieSource == .manual else { return nil }
        return context.settings?.factory?.manualCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
