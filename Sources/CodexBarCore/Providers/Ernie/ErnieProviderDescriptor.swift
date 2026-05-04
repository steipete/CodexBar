import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ErnieProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .ernie,
            metadata: ProviderMetadata(
                id: .ernie,
                displayName: "ERNIE",
                sessionLabel: "Status",
                weeklyLabel: "Models",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ERNIE usage",
                cliName: "ernie",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.bce.baidu.com/qianfan/overview",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .ernie,
                iconResourceName: "ProviderIcon-ernie",
                color: ProviderColor(red: 0.15, green: 0.45, blue: 0.85)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ERNIE cost summary is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ErnieWebFetchStrategy(), ErnieAPIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "ernie",
                aliases: ["qianfan", "wenxin", "baidu"],
                versionDetector: nil))
    }
}

struct ErnieAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "ernie.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw ErnieUsageError.missingCredentials
        }
        let usage = try await ErnieUsageFetcher.verifyAPI(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        true
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.ernieToken(environment: environment)
    }
}

struct ErnieWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "ernie.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.ernieWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if ErnieCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        #if os(macOS)
        if context.settings?.ernie?.cookieSource != .off {
            return ErnieCookieImporter.hasSession()
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let cookieHeader = self.resolveCookieHeader(context: context) else {
            throw ErnieUsageError.missingCookie
        }

        let snapshot = try await ErnieUsageFetcher.fetchBalance(cookieHeader: cookieHeader)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case ErnieUsageError.missingCookie = error { return false }
        return true
    }

    private func resolveCookieHeader(context: ProviderFetchContext) -> String? {
        if let override = ErnieCookieHeader.resolveCookieOverride(context: context) {
            return override.cookieHeader
        }

        #if os(macOS)
        if context.settings?.ernie?.cookieSource != .off {
            do {
                let session = try ErnieCookieImporter.importSession()
                if let header = session.cookieHeader {
                    return header
                }
            } catch {
                Self.log.debug("Ernie browser cookie import failed: \(error)")
            }
        }
        #endif

        return nil
    }
}
