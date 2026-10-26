import CodexBarCore
import Foundation

extension UsageStore {
    static func debugNotionLog(
        browserDetection: BrowserDetection,
        notionCookieSource: ProviderCookieSource,
        notionCookieHeader: String,
        notionWorkspaceID: String) async -> String
    {
        await runWithTimeout(seconds: 15) {
            let context = ProviderFetchContext(
                runtime: .app,
                sourceMode: .web,
                includeCredits: false,
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
                let usage = try await NotionProviderDescriptor.webStrategy().fetch(context).usage
                let rolling = usage.primary?.usedPercent.description ?? "unavailable"
                let monthly = usage.secondary?.usedPercent.description ?? "unavailable"
                return "Notion plugin fetch succeeded\nRolling used: \(rolling)\nMonthly used: \(monthly)"
            } catch {
                return "Notion plugin fetch failed: \(error.localizedDescription)"
            }
        }
    }
}
