import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AlibabaProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .alibaba,
            metadata: ProviderMetadata(
                id: .alibaba,
                displayName: "Alibaba Model Studio",
                sessionLabel: "5 hours",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Alibaba usage",
                cliName: "alibaba",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=globalset#/efm/coding_plan",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .custom,
                iconResourceName: "ProviderIcon-alibaba",
                color: ProviderColor(red: 1.0, green: 0.4, blue: 0.2)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Alibaba cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "alibaba",
                aliases: ["dashscope", "coding-plan"],
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .web:
            return [AlibabaWebFetchStrategy()]
        case .auto:
            break
        case .api, .cli, .oauth:
            return []
        }
        // Default to web scraping (requires browser cookies)
        return [AlibabaWebFetchStrategy()]
    }
}

struct AlibabaWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "alibaba.web"
    let kind: ProviderFetchKind = .webCookies

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check if user has cookies for alibabacloud.com
        return context.cookieImporter.hasCookies(for: "alibabacloud.com")
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Load console in WebView and extract usage data
        let usage = try await AlibabaUsageFetcher.fetchUsage(
            cookieImporter: context.cookieImporter,
            webViewAPI: context.webViewAPI,
            webTimeout: context.webTimeout
        )
        return self.makeResult(usage: usage, sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        // No fallback available
        return false
    }
}
