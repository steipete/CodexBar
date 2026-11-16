import CodexBarCore
import Foundation

extension UsageStore {
    static func debugNotionLog(
        browserDetection: BrowserDetection,
        notionCookieSource: ProviderCookieSource,
        notionCookieHeader: String,
        notionWorkspaceID: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        probeTimeout: TimeInterval = 20) async -> String
    {
        // This bounded diagnostic reports only allowances; optional credits cannot delay it.
        await runWithTimeout(seconds: probeTimeout) {
            let context = ProviderFetchContext(
                runtime: .app,
                sourceMode: .web,
                includeCredits: false,
                includeOptionalUsage: false,
                webTimeout: 15,
                webDebugDumpHTML: false,
                verbose: false,
                env: [:],
                settings: .make(notion: .init(
                    cookieSource: notionCookieSource,
                    manualCookieHeader: notionCookieHeader,
                    workspaceID: notionWorkspaceID)),
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: [:]),
                browserDetection: browserDetection)
            do {
                let usage = try await NotionProviderDescriptor.webStrategy(transport: transport).fetch(context).usage
                let descriptor = NotionProviderDescriptor.descriptor
                let labels = descriptor.presentation.rateWindowLabels(metadata: descriptor.metadata, snapshot: usage)
                let primary = usage.primary?.usedPercent.description ?? "unavailable"
                let secondary = usage.secondary?.usedPercent.description ?? "unavailable"
                return [
                    "Notion plugin fetch succeeded",
                    "\(labels.primary) used: \(primary)",
                    "\(labels.secondary) used: \(secondary)",
                ].joined(separator: "\n")
            } catch {
                return "Notion plugin fetch failed: \(error.localizedDescription)"
            }
        }
    }
}
