import Foundation

public enum HyperProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .hyper,
            metadata: ProviderMetadata(
                id: .hyper,
                displayName: "Charm Hyper",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Charm Hyper usage",
                cliName: "hyper",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.chromeOnlyImportOrder,
                dashboardURL: "https://hyper.charm.land",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .hyper,
                iconResourceName: "ProviderIcon-hyper",
                color: ProviderColor(red: 1, green: 96 / 255, blue: 1),
                confettiPalette: [
                    ProviderColor(red: 1, green: 96 / 255, blue: 1),
                    ProviderColor(red: 1, green: 1, blue: 1),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Charm Hyper cost history is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(name: "hyper", aliases: [], versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .web:
            [HyperSessionFetchStrategy()]
        case .api:
            [HyperAPIFetchStrategy()]
        case .auto:
            if context.settings?.hyper?.cookieSource == .off {
                [HyperAPIFetchStrategy()]
            } else {
                [HyperSessionFetchStrategy(), HyperAPIFetchStrategy()]
            }
        case .cli, .oauth:
            []
        }
    }
}

struct HyperSessionFetchStrategy: ProviderFetchStrategy {
    let id = "hyper.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let cookieSource = context.settings?.hyper?.cookieSource ?? .auto
        guard cookieSource != .off else { return false }
        if cookieSource == .manual {
            return CookieHeaderNormalizer.normalize(context.settings?.hyper?.manualCookieHeader) != nil
        }
        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .hyper),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        return HyperCookieImporter.hasSession(browserDetection: context.browserDetection)
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieHeader = try Self.resolveCookieHeader(context: context)
        do {
            let usage = try await HyperUsageFetcher.fetchUsage(cookieHeader: cookieHeader)
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "web")
        } catch HyperUsageError.missingCredentials {
            if context.settings?.hyper?.cookieSource != .manual {
                CookieHeaderCache.clear(provider: .hyper)
            }
            throw HyperUsageError.missingCredentials
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return false
        }
        guard let error = error as? HyperUsageError else { return true }
        switch error {
        case .missingCredentials, .networkError:
            return true
        case .apiError, .parseFailed:
            return false
        }
    }

    private static func resolveCookieHeader(context: ProviderFetchContext) throws -> String {
        if context.settings?.hyper?.cookieSource == .manual {
            guard let header = CookieHeaderNormalizer.normalize(context.settings?.hyper?.manualCookieHeader) else {
                throw HyperUsageError.missingCredentials
            }
            return header
        }

        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .hyper),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return cached.cookieHeader
        }
        let session = try HyperCookieImporter.importSession(browserDetection: context.browserDetection)
        CookieHeaderCache.store(provider: .hyper, cookieHeader: session.cookieHeader, sourceLabel: session.sourceLabel)
        return session.cookieHeader
        #else
        throw HyperUsageError.missingCredentials
        #endif
    }
}

struct HyperAPIFetchStrategy: ProviderFetchStrategy {
    let id = "hyper.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        // Keep this strategy available so a missing key yields provider-specific setup guidance.
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.hyperToken(environment: context.env) else {
            throw HyperUsageError.missingCredentials
        }
        let usage = try await HyperUsageFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
