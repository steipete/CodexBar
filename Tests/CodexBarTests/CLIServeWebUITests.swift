import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeWebUITests {
    private var html: String {
        String(bytes: CLIServeWebUI.response().body, encoding: .utf8) ?? ""
    }

    @Test
    func `web ui renders account cards in titled groups for multi account providers`() {
        let html = self.html
        // Multi-account providers render one card per account inside a titled
        // vertical group; identity falls back to the slot label when redacted.
        #expect(html.contains("function renderAccountCard(provider, account)"))
        #expect(html.contains("account.identity?.accountEmail || account.label"))
        #expect(html.contains("provider.accountsError"))
        #expect(html.contains("group-title"))
    }

    @Test
    func `web ui embeds provider icon urls and serves embedded svgs`() {
        let html = self.html
        // The placeholder must be substituted at render time with a JSON map.
        #expect(!html.contains("__PROVIDER_ICON_URLS__"))
        #expect(html.contains("/icons/ProviderIcon-claude.svg"))
        #expect(CLIServeWebUI.iconResponse(name: "ProviderIcon-claude") != nil)
        #expect(CLIServeWebUI.iconResponse(name: "ProviderIcon-nonexistent") == nil)
        #expect(CLIServeWebUI.iconResponse(name: "../etc/passwd") == nil)
    }

    @Test
    func `web ui keeps ambient windows when no accounts are present`() {
        let html = self.html
        #expect(html.contains("Array.isArray(provider.accounts)"))
        #expect(html.contains("renderWindow(window)"))
    }

    @Test
    func `web ui renders daily spend charts from cost history`() {
        let html = self.html
        // Chart data rides /cost daily buckets keyed by provider; rendering is
        // skipped for zero-spend or single-day histories, and a /cost failure
        // must never block the snapshot render.
        #expect(html.contains("function renderCostChart(history)"))
        #expect(html.contains("refreshCostHistory(headers)"))
        #expect(html.contains("state.costHistories[provider.id]"))
        #expect(html.contains("fetch(\"/cost\""))
    }

    @Test
    func `web ui progressively paints cached shell and provider snapshots`() {
        let html = self.html
        #expect(html.contains("codexbar.lastSnapshot"))
        #expect(html.contains("/dashboard/v1/snapshot?detail=shell"))
        #expect(html.contains("card pending"))
        #expect(html.contains("Promise.allSettled"))
        #expect(html.contains("encodeURIComponent(provider.id)"))
    }

    @Test
    func `serve identity flag decodes like the dashboard command`() {
        #expect(CodexBarCLI.decodeDashboardIdentityMode(
            from: ParsedValues(positional: [], options: [:], flags: [])) == .full)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(
            from: ParsedValues(positional: [], options: ["identity": ["redacted"]], flags: [])) == .redacted)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(
            from: ParsedValues(positional: [], options: ["identity": ["full"]], flags: [])) == .full)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(
            from: ParsedValues(positional: [], options: ["identity": ["nope"]], flags: [])) == nil)
    }
}
