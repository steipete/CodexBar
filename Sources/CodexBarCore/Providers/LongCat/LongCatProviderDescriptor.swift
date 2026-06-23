import Foundation

public enum LongCatProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .longcat,
            metadata: ProviderMetadata(
                id: .longcat,
                displayName: "LongCat",
                sessionLabel: "Quota",
                weeklyLabel: "Fuel Pack",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show LongCat usage",
                cliName: "longcat",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://longcat.chat/platform/",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .longcat,
                iconResourceName: "ProviderIcon-longcat",
                color: ProviderColor(red: 255 / 255, green: 209 / 255, blue: 0 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "LongCat cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [LongCatWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "longcat",
                aliases: ["long-cat", "lc"],
                versionDetector: nil))
    }
}

struct LongCatWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "longcat.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.longcatWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if LongCatCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        #if os(macOS)
        if self.allowsBrowserImport(context) {
            return LongCatCookieImporter.hasSession()
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let cookieHeader = self.resolveCookieHeader(context: context) else {
            throw LongCatAPIError.missingCookies
        }

        let snapshot = try await LongCatUsageFetcher.fetchUsage(cookieHeader: cookieHeader)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        if case LongCatAPIError.missingCookies = error { return false }
        if case LongCatAPIError.invalidSession = error { return false }
        return true
    }

    private func resolveCookieHeader(context: ProviderFetchContext) -> String? {
        if let override = LongCatCookieHeader.resolveCookieOverride(context: context) {
            return override.cookieHeader
        }

        #if os(macOS)
        if self.allowsBrowserImport(context) {
            if let session = try? LongCatCookieImporter.importSession(),
               let header = session.cookieHeader
            {
                return header
            }
        }
        #endif

        return nil
    }

    /// Browser cookie/keychain import is only used for the Auto source (the
    /// default). Manual must use the pasted header and Off disables web auth, so
    /// neither should silently fall back to a browser session.
    private func allowsBrowserImport(_ context: ProviderFetchContext) -> Bool {
        let source = context.settings?.longcat?.cookieSource
        return source == nil || source == .auto
    }
}
