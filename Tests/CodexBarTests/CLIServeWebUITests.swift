import Commander
import Foundation
import JavaScriptCore
import Testing
@testable import CodexBarCLI

struct CLIServeWebUITests {
    private var html: String {
        String(bytes: CLIServeWebUI.response().body, encoding: .utf8) ?? ""
    }

    @Test(arguments: [true, false])
    func `shared costs and diagnostics survive account grouping without sharing credits`(grouped: Bool) throws {
        let context = try self.recordingContext()
        context.evaluateScript("fixture.providers[0].accounts = \(grouped) ? fixture.providers[0].accounts : [];")
        context.evaluateScript("renderSnapshot(fixture);")
        #expect(context.exception == nil)
        let text = try #require(context.evaluateScript("recordedText(elements.providers)")?.toArray() as? [String])
        for value in ["$2.00", "$5.00", "Synthetic adapter note"] {
            #expect(text.filter { $0 == value }.count == 1)
        }
        #expect(text.filter { $0.contains("Synthetic provider diagnostic") }.count == 1)
        #expect(text.contains("Provider data: Synthetic provider diagnostic") == grouped)
        #expect(text.contains("Remaining") == !grouped)
        #expect(text.contains("ambient@example.test") == !grouped)
        for value in ["Synthetic account A note", "Synthetic account B note", "Claude local spend"] {
            #expect(text.filter { $0 == value }.count == (grouped ? 1 : 0))
        }
        #expect(context.evaluateScript(
            "recordedNodes(elements.providers).filter(x => x.tagName === 'svg').length")?.toInt32() == 1)
    }

    @Test
    func `account group omits an empty shared cost card`() throws {
        let context = try self.recordingContext()
        context.evaluateScript("fixture.providers[0].cost = null; state.costHistories = {}; renderSnapshot(fixture);")
        #expect(context.exception == nil)
        let text = try #require(context.evaluateScript("recordedText(elements.providers)")?.toArray() as? [String])
        #expect(!text.contains("Claude local spend"))
        #expect(text.contains("Provider data: Synthetic provider diagnostic"))
        #expect(context.evaluateScript(
            "recordedNodes(elements.providers).filter(x => x.tagName === 'article').length")?.toInt32() == 2)
    }

    private func recordingContext() throws -> JSContext {
        let context = try #require(JSContext())
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("WebUI")
        try context.evaluateScript(String(contentsOf: root.appendingPathComponent("recording-dom.js"), encoding: .utf8))
        let start = try #require(self.html.range(of: "<script>"))
        let end = try #require(self.html.range(of: "</script>"))
        context.evaluateScript(String(self.html[start.upperBound..<end.lowerBound]))
        let fixture = try String(
            contentsOf: root.appendingPathComponent("account-group-snapshot.json"),
            encoding: .utf8)
        context.evaluateScript("const fixture = \(fixture);")
        context.evaluateScript("""
        state.costHistories.claude = [{date:'2026-09-13',cost:3},{date:'2026-09-14',cost:2}];
        """)
        #expect(context.exception == nil)
        return context
    }

    @Test
    func `web ui renders account cards in titled groups for multi account providers`() {
        let html = self.html
        // Multi-account providers render one card per account inside a titled
        // vertical group; account labels retain the producer's disambiguation.
        #expect(html.contains("function renderAccountCard(provider, account)"))
        #expect(html.contains("provider.accountsError"))
        #expect(html.contains("group-title"))
    }

    @Test
    func `account cards preserve projected labels before falling back to email`() throws {
        let start = try #require(self.html.range(of: "function renderAccountCard(provider, account)"))
        let end = try #require(self.html.range(of: "function renderProvider(provider)"))
        let renderer = String(self.html[start.lowerBound..<end.lowerBound])
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        const titles = [];
        function node(tag, className, text) {
          if (className === "provider-name") titles.push(text);
          return {style: {setProperty() {}}, classList: {add() {}}, append() {}};
        }
        function providerGlyph() { return node("span"); }
        function accentColor(value) { return value; }
        function visibleWindows(windows) { return windows || []; }
        function worstWindowLevel() { return null; }
        """#)
        context.evaluateScript(renderer)
        context.evaluateScript(#"""
        for (const account of [
          {label: "Work", identity: {accountEmail: "shared@example.com"}},
          {label: "shared@example.com · Acme", identity: {accountEmail: "shared@example.com"}},
          {label: "Account 1", identity: {accountEmail: "s***@example.com"}},
          {label: "s***@example.com · Acme", identity: {accountEmail: "s***@example.com"}},
          {label: "", identity: {accountEmail: "fallback@example.com"}},
          {}
        ]) renderAccountCard({}, account);
        """#)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("titles")?.toArray() as? [String] == [
            "Work", "shared@example.com · Acme", "Account 1", "s***@example.com · Acme",
            "fallback@example.com", "Account",
        ])
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
    func `web ui renders account windows alongside an error note`() {
        let html = self.html
        let errorAppend = "card.append(node(\"p\", \"error-message\", account.error));"
        #expect(html.contains(errorAppend))
        #expect(!html.contains(errorAppend + "\n            return card;"))
        #expect(html.contains(
            "for (const window of visibleWindows(account.windows)) windows.append(renderWindow(window))"))
    }

    @Test
    func `web ui skips windows the snapshot marks idle`() {
        let html = self.html
        // The producer decides which lanes are idle, so the page must not repeat any
        // provider-specific rule. It filters on the generic flag and nothing else.
        #expect(html.contains("function visibleWindows(windows)"))
        #expect(html.contains("w.idle !== true"))
        #expect(html.contains("for (const window of visibleWindows(provider.windows))"))
        #expect(html.contains("for (const window of visibleWindows(account.windows))"))
        #expect(html.contains("worstWindowLevel(visibleWindows(account.windows))"))
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
