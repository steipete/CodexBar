import Commander
import Foundation
import JavaScriptCore
import Testing
@testable import CodexBarCLI

struct CLIServeWebUITests {
    private var html: String {
        String(bytes: CLIServeWebUI.response().body, encoding: .utf8) ?? ""
    }

    @Test(arguments: [false, true], [false, true])
    func `window labels widths and accessibility values follow the selected fill mode`(
        showUsed: Bool,
        hasRemainingPercent: Bool) throws
    {
        let context = try self.recordingContext()
        context.evaluateScript("""
        state.snapshot = {host: {usageBarsShowUsed: \(showUsed)}};
        const quota = {label: "Session", usedPercent: 25};
        if (\(hasRemainingPercent)) quota.remainingPercent = 75;
        const rendered = renderWindow(quota);
        """)
        #expect(context.exception == nil)
        let value = showUsed ? 25 : 75
        let suffix = showUsed ? "used" : "left"
        #expect(context.evaluateScript("recordedText(rendered)[0]")?.toString() == "Session · \(value)% \(suffix)")
        #expect(context.evaluateScript(
            "recordedNodes(rendered).find(node => node.className === 'fill').style.width")?.toString() == "\(value)%")
        #expect(context.evaluateScript(
            "recordedNodes(rendered).find(node => node.className === 'track').attributes['aria-valuenow']")?
            .toString() ==
            String(value))
    }

    @Test
    func `older browser snapshots without a fill hint use the remaining default`() throws {
        let context = try self.recordingContext()
        context.evaluateScript("""
        state.snapshot = {};
        const rendered = renderWindow({label: "Session", usedPercent: 25});
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("recordedText(rendered)[0]")?.toString() == "Session · 75% left")
        #expect(context.evaluateScript(
            "recordedNodes(rendered).find(node => node.className === 'fill').style.width")?.toString() == "75%")
    }

    @Test(arguments: [false, true])
    func `account-group windows share the host fill preference`(showUsed: Bool) throws {
        let context = try self.recordingContext()
        context.evaluateScript("fixture.host.usageBarsShowUsed = \(showUsed); renderSnapshot(fixture);")
        #expect(context.exception == nil)
        let widths = context.evaluateScript(
            "recordedNodes(elements.providers).filter(node => node.className === 'fill')" +
                ".map(node => node.style.width)")?
            .toArray() as? [String]
        #expect(widths == (showUsed ? ["20%", "40%", "70%", "10%"] : ["80%", "60%", "30%", "90%"]))
    }

    @Test
    func `export optional synthetic fill preference proof pages`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_SERVE_FILL_PROOF_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("WebUI/account-group-snapshot.json")
        var snapshot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures)) as? [String: Any])
        snapshot["generatedAt"] = ISO8601DateFormatter().string(from: Date())
        var host = try #require(snapshot["host"] as? [String: Any])
        for showUsed in [false, true] {
            host["usageBarsShowUsed"] = showUsed
            snapshot["host"] = host
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            let fixture = try #require(String(bytes: data, encoding: .utf8))
                .replacingOccurrences(of: "</", with: "<\\/")
            var html = self.html
            if let icon = CLIServeWebUI.iconResponse(name: "ProviderIcon-claude") {
                html = html.replacingOccurrences(
                    of: "/icons/ProviderIcon-claude.svg",
                    with: "data:image/svg+xml;base64," + icon.body.base64EncodedString())
            }
            let start = try #require(html.range(of: "<script>"))
            let end = try #require(html.range(of: "</script>"))
            var script = String(html[start.upperBound..<end.lowerBound])
            let bootstrap = try #require(script.range(of: "const cached = storedSnapshot();", options: .backwards))
            let fill = try #require(script.range(
                of: "startProgressiveFill();",
                range: bootstrap.lowerBound..<script.endIndex))
            script.replaceSubrange(bootstrap.lowerBound..<fill.upperBound, with: "renderSnapshot(\(fixture));")
            let isolated = """
            (() => {
            const localStorage = {getItem: () => null, setItem() {}, removeItem() {}};
            const fetch = () => Promise.reject(new Error("Synthetic proof has no network"));
            const setTimeout = () => 0, setInterval = () => 0, clearTimeout = () => {};
            \(script)
            })();
            """
            html.replaceSubrange(start.upperBound..<end.lowerBound, with: isolated)
            let name = showUsed ? "serve-used.html" : "serve-remaining.html"
            try html.write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    @Test(arguments: [true, false], ["en-US", "de-DE"])
    func `shared costs and diagnostics survive account grouping without sharing credits`(
        grouped: Bool, locale: String) throws
    {
        let context = try self.recordingContext(locale: locale)
        context.evaluateScript("fixture.providers[0].accounts = \(grouped) ? fixture.providers[0].accounts : [];")
        context.evaluateScript("renderSnapshot(fixture);")
        #expect(context.exception == nil)
        let text = try #require(context.evaluateScript("recordedText(elements.providers)")?.toArray() as? [String])
        let twoDollars = try #require(context.evaluateScript("dollars(2)")?.toString())
        let fiveDollars = try #require(context.evaluateScript("dollars(5)")?.toString())
        #expect(fiveDollars.contains(",") == (locale == "de-DE"))
        for value in [twoDollars, fiveDollars, "Synthetic adapter note"] {
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

    @Test(arguments: [true, false], ["en-US", "de-DE"])
    func `partial cost summaries and chart gaps survive grouped and single cards`(
        grouped: Bool, locale: String) throws
    {
        let context = try self.recordingContext(locale: locale)
        context.evaluateScript("""
        fixture.providers[0].accounts = \(grouped) ? fixture.providers[0].accounts : [];
        fixture.providers[0].cost = {todayUSD:null, last30DaysUSD:5,
          todayIncompleteRequestCount:1, last30DaysIncompleteRequestCount:2};
        state.costHistories.claude = [
          {date:'2026-09-14',cost:2},
          {date:'2026-09-15',cost:3,incompleteRequestCount:1},
          {date:'2026-09-16',cost:null,incompleteRequestCount:1}];
        renderSnapshot(fixture);
        """)
        #expect(context.exception == nil)
        let text = try #require(context.evaluateScript("recordedText(elements.providers)")?.toArray() as? [String])
        #expect(text.contains("— · Incomplete"))
        let fiveDollars = try #require(context.evaluateScript("dollars(5)")?.toString())
        #expect(text.contains(fiveDollars + " · Incomplete"))
        #expect(text.contains("2026-09-16 · — · Incomplete: 1 excluded requests"))
        let zeroDollars = try #require(context.evaluateScript("dollars(0)")?.toString())
        #expect(!text.contains("2026-09-16 · " + zeroDollars))
        #expect(context.evaluateScript("""
        recordedNodes(elements.providers).find(x => x.tagName === 'svg').attributes['aria-label']
        """)?.toString()?.contains("incomplete usage") == true)
        context.evaluateScript("""
        const missingChart = renderCostChart([{date:'2026-09-16',cost:null,incompleteRequestCount:1}]);
        const zeroChart = renderCostChart([{date:'2026-09-16',cost:0}]);
        """)
        #expect(context.evaluateScript("missingChart !== null && zeroChart === null")?.toBool() == true)
    }

    @Test
    func `cost route preserves nullable daily amounts before chart rendering`() throws {
        let rows = """
        [{"provider":"claude","daily":[{"date":"2026-09-15","totalCost":0},
        {"date":"2026-09-16","incompleteRequestCount":1}]}]
        """
        let context = try self.recordingContext(costJSON: rows)
        context.evaluateScript("refreshCostHistory({});")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("state.costHistories.claude[0].cost === 0")?.toBool() == true)
        #expect(context.evaluateScript("state.costHistories.claude[1].cost === null")?.toBool() == true)
        #expect(context.evaluateScript("state.costHistories.claude[1].incompleteRequestCount")?.toInt32() == 1)
    }

    @Test
    func `render synthetic incomplete cost dashboard proof`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_INCOMPLETE_PROOF_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for before in [true, false] {
            let snapshot: [String: Any] = [
                "schemaVersion": 1,
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "staleAfterSeconds": 86400,
                "host": ["refreshIntervalSeconds": 60],
                "providers": [[
                    "id": "claude",
                    "name": "Claude",
                    "enabled": true,
                    "display": ["sortKey": 0, "accentColor": "#C58060"],
                    "windows": [],
                    "cost": before ? ["todayUSD": 0.3224, "last30DaysUSD": 1.4848] : [
                        "todayUSD": NSNull(),
                        "last30DaysUSD": 0.84,
                        "todayIncompleteRequestCount": 1,
                        "last30DaysIncompleteRequestCount": 2,
                    ],
                ]],
            ]
            let history: [[String: Any]] = before ? [
                ["date": "2026-09-14", "cost": 0.4],
                ["date": "2026-09-15", "cost": 0.7624],
                ["date": "2026-09-16", "cost": 0.3224],
            ] : [
                ["date": "2026-09-14", "cost": 0.4],
                ["date": "2026-09-15", "cost": 0.44, "incompleteRequestCount": 1],
                ["date": "2026-09-16", "cost": NSNull(), "incompleteRequestCount": 1],
            ]
            func json(_ value: Any) throws -> String {
                try #require(String(
                    data: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                    encoding: .utf8))
                    .replacingOccurrences(of: "</", with: "<\\/")
            }
            var html = self.html
            if let icon = CLIServeWebUI.iconResponse(name: "ProviderIcon-claude") {
                html = html.replacingOccurrences(
                    of: "/icons/ProviderIcon-claude.svg",
                    with: "data:image/svg+xml;base64," + icon.body.base64EncodedString())
            }
            let start = try #require(html.range(of: "<script>"))
            let end = try #require(html.range(of: "</script>"))
            var script = String(html[start.upperBound..<end.lowerBound])
            let bootstrap = try #require(script.range(of: "const cached = storedSnapshot();", options: .backwards))
            let fill = try #require(script.range(
                of: "startProgressiveFill();",
                range: bootstrap.lowerBound..<script.endIndex))
            try script.replaceSubrange(
                bootstrap.lowerBound..<fill.upperBound,
                with:
                "state.costHistories.claude = \(json(history)); renderSnapshot(\(json(snapshot)));")
            let isolated = """
            (() => {
            const localStorage = {getItem: () => null, setItem() {}, removeItem() {}};
            const fetch = () => Promise.reject(new Error("Synthetic proof has no network"));
            const setTimeout = () => 0, setInterval = () => 0, clearTimeout = () => {};
            \(script)
            })();
            """
            html.replaceSubrange(start.upperBound..<end.lowerBound, with: isolated)
            try html.write(
                to: output.appendingPathComponent(before ? "claude-before.html" : "claude-after.html"),
                atomically: true,
                encoding: .utf8)
        }
    }

    private func recordingContext(costJSON: String? = nil, locale: String? = nil) throws -> JSContext {
        let context = try #require(JSContext())
        if let locale {
            let localeJSON = try #require(String(data: JSONEncoder().encode(locale), encoding: .utf8))
            context.evaluateScript("""
            const nativeNumberFormat = Intl.NumberFormat;
            Intl.NumberFormat = function(locales, options) {
              return new nativeNumberFormat(locales ?? \(localeJSON), options);
            };
            """)
        }
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("WebUI")
        var dom = try String(contentsOf: root.appendingPathComponent("recording-dom.js"), encoding: .utf8)
        if let costJSON {
            dom = dom.replacingOccurrences(
                of: "const fetch = () => new Promise(() => {});",
                with:
                "const fetch = url => url === '/cost' ? Promise.resolve({ok:true, json:async()=>\(costJSON)}) "
                    + ": new Promise(() => {});")
        }
        context.evaluateScript(dom)
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
            "Work",
            "shared@example.com · Acme",
            "Account 1",
            "s***@example.com · Acme",
            "fallback@example.com",
            "Account",
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
