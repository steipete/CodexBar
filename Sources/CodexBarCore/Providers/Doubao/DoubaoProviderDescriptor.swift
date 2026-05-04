import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum DoubaoProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .doubao,
            metadata: ProviderMetadata(
                id: .doubao,
                displayName: "Doubao",
                sessionLabel: "Status",
                weeklyLabel: "Endpoints",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Doubao usage",
                cliName: "doubao",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.volcengine.com/ark",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .doubao,
                iconResourceName: "ProviderIcon-doubao",
                color: ProviderColor(red: 0.0, green: 0.55, blue: 0.95)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Doubao cost summary is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [DoubaoWebFetchStrategy(), DoubaoAPIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "doubao",
                aliases: ["volcengine", "ark"],
                versionDetector: nil))
    }
}

struct DoubaoAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "doubao.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw DoubaoUsageError.missingCredentials
        }
        let usage = try await DoubaoUsageFetcher.verifyAPI(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        true
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.doubaoToken(environment: environment)
    }
}

struct DoubaoWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "doubao.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.doubaoWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if DoubaoCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        #if os(macOS)
        if context.settings?.doubao?.cookieSource != .off {
            return DoubaoCookieImporter.hasSession()
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let cookieHeader = self.resolveCookieHeader(context: context) else {
            throw DoubaoUsageError.missingCookie
        }

        let snapshot = try await DoubaoUsageFetcher.fetchBalance(cookieHeader: cookieHeader)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case DoubaoUsageError.missingCookie = error { return false }
        return true
    }

    private func resolveCookieHeader(context: ProviderFetchContext) -> String? {
        if let override = DoubaoCookieHeader.resolveCookieOverride(context: context) {
            return override.cookieHeader
        }

        #if os(macOS)
        if context.settings?.doubao?.cookieSource != .off {
            do {
                let session = try DoubaoCookieImporter.importSession()
                if let header = session.cookieHeader {
                    return header
                }
            } catch {
                Self.log.debug("Doubao browser cookie import failed: \(error)")
            }
        }
        #endif

        return nil
    }
}
