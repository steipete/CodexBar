import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ZhipuProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zhipu,
            metadata: ProviderMetadata(
                id: .zhipu,
                displayName: "Zhipu",
                sessionLabel: "Status",
                weeklyLabel: "Models",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Zhipu usage",
                cliName: "zhipu",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://open.bigmodel.cn/usercenter/apikeys",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .zhipu,
                iconResourceName: "ProviderIcon-zhipu",
                color: ProviderColor(red: 0.0, green: 0.45, blue: 0.85)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Zhipu cost summary is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ZhipuWebFetchStrategy(), ZhipuAPIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "zhipu",
                aliases: ["glm", "chatglm"],
                versionDetector: nil))
    }
}

struct ZhipuAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "zhipu.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw ZhipuUsageError.missingCredentials
        }
        let usage = try await ZhipuUsageFetcher.verifyAPI(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        true
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.zhipuToken(environment: environment)
    }
}

struct ZhipuWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "zhipu.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.zhipuWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if ZhipuCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        #if os(macOS)
        if context.settings?.zhipu?.cookieSource != .off {
            return ZhipuCookieImporter.hasSession()
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let cookieHeader = self.resolveCookieHeader(context: context) else {
            throw ZhipuUsageError.missingCookie
        }

        let snapshot = try await ZhipuUsageFetcher.fetchBalance(cookieHeader: cookieHeader)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case ZhipuUsageError.missingCookie = error { return false }
        return true
    }

    private func resolveCookieHeader(context: ProviderFetchContext) -> String? {
        if let override = ZhipuCookieHeader.resolveCookieOverride(context: context) {
            return override.cookieHeader
        }

        #if os(macOS)
        if context.settings?.zhipu?.cookieSource != .off {
            do {
                let session = try ZhipuCookieImporter.importSession()
                if let header = session.cookieHeader {
                    return header
                }
            } catch {
                Self.log.debug("Zhipu browser cookie import failed: \(error)")
            }
        }
        #endif

        return nil
    }
}
