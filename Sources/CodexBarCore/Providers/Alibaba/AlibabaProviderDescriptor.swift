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
                iconStyle: .alibaba,
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
    let kind: ProviderFetchKind = .webDashboard

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Web strategy is available when source mode allows web
        return context.sourceMode.usesWeb
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Ensure AppKit is initialized before using WebKit in a CLI.
        await MainActor.run {
            _ = NSApplication.shared
        }

        // Use fetcher's browser detection for cookie access
        let browserDetection = context.browserDetection
        
        // Check if user has browser cookies for alibabacloud.com
        // This uses the browserDetection to check cookie availability
        let hasCookies = await browserDetection.hasCookies(for: "alibabacloud.com")
        guard hasCookies else {
            throw AlibabaUsageError.missingCookies
        }

        // Fetch usage via WebView scraping
        let options = AlibabaWebOptions(
            timeout: context.webTimeout,
            debugDumpHTML: context.webDebugDumpHTML,
            verbose: context.verbose
        )
        
        let usage = try await Self.fetchAlibabaWeb(
            browserDetection: browserDetection,
            options: options
        )
        
        return self.makeResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "alibaba-web"
        )
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) async -> Bool {
        guard context.sourceMode == .auto else { return false }
        // Fallback on cookie errors or page load failures
        if case AlibabaUsageError.missingCookies = error { return true }
        if case AlibabaUsageError.pageLoadFailed = error { return true }
        return false
    }
}

private struct AlibabaWebOptions {
    let timeout: TimeInterval
    let debugDumpHTML: Bool
    let verbose: Bool
}

@MainActor
extension AlibabaWebFetchStrategy {
    fileprivate static func fetchAlibabaWeb(
        browserDetection: BrowserDetection,
        options: AlibabaWebOptions
    ) async throws -> UsageSnapshot {
        // Use browser detection to access cookies and create WebView
        // This follows the same pattern as CodexWebDashboardStrategy
        try await AlibabaUsageFetcher.fetchUsage(
            browserDetection: browserDetection,
            timeout: options.timeout,
            debugDumpHTML: options.debugDumpHTML,
            verbose: options.verbose
        )
    }
}
