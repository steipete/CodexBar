import Commander
import Foundation
import JavaScriptCore
import Testing
@testable import CodexBarCLI

struct CLIServeWebUITests {
    private var html: String {
        String(bytes: CLIServeWebUI.response().body, encoding: .utf8) ?? ""
    }

    @Test(arguments: ["server", "used", "remaining"], [false, true])
    func `browser choice overrides both labels and widths without changing consumption status`(
        choice: String, serverUsed: Bool) throws
    {
        let context = try self.recordingContext()
        context.evaluateScript("""
        fixture.host.usageBarsShowUsed = \(serverUsed);
        renderSnapshot(fixture);
        elements.error.classList.add('visible');
        state.forceStale = true;
        elements.usageDisplay.value = '\(choice)';
        changeUsageDisplay();
        const rendered = renderWindow({label:'Session', usedPercent:90, remainingPercent:10});
        """)
        let showUsed = choice == "used" || (choice == "server" && serverUsed)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("recordedText(rendered)[0]")?.toString() ==
            (showUsed ? "Session · 90% used" : "Session · 10% left"))
        #expect(context.evaluateScript(
            "recordedNodes(rendered).find(node => node.className === 'fill').style.width")?.toString() ==
            (showUsed ? "90%" : "10%"))
        #expect(context.evaluateScript(
            "recordedNodes(rendered).find(node => node.className === 'track').attributes['aria-valuenow']")?
            .toString() == (showUsed ? "90" : "10"))
        #expect(context.evaluateScript("worstWindowLevel([{usedPercent:95}])")?.toString() == "critical")
        #expect(context.evaluateScript("worstWindowLevel([{usedPercent:80}])")?.toString() == "warning")
        #expect(context.evaluateScript("fixture.host.usageBarsShowUsed")?.toBool() == serverUsed)
        #expect(context.evaluateScript("elements.error.className.includes('visible') && state.forceStale")?
            .toBool() == true)
        let widths = context.evaluateScript(
            "recordedNodes(elements.providers).filter(node => node.className === 'fill')" +
                ".map(node => node.style.width)")?
            .toArray() as? [String]
        #expect(widths == (showUsed ? ["20%", "40%", "70%", "10%"] : ["80%", "60%", "30%", "90%"]))
    }

    @Test(arguments: ["used", "remaining", "server", "unknown", "{malformed", "null"])
    func `saved browser choice is validated during page initialization`(saved: String) throws {
        let context = try self.recordingContext(storageSetup: """
        localStorage.getItem = key => key === 'codexbar.dashboard.usageDisplay' ? '\(saved)' : null;
        """)
        let expected = ["used", "remaining"].contains(saved) ? saved : "server"
        #expect(context.evaluateScript("state.usageDisplay")?.toString() == expected)
        #expect(context.evaluateScript("elements.usageDisplay.value")?.toString() == expected)
    }

    @Test
    func `browser choices persist and follow server removes only the display override`() throws {
        let context = try self.recordingContext(storageSetup: """
        const saved = {'codexbar.dashboardToken':'synthetic', 'codexbar.lastSnapshot':'null'};
        localStorage.getItem = key => saved[key] ?? null;
        localStorage.setItem = (key, value) => saved[key] = value;
        localStorage.removeItem = key => delete saved[key];
        """)
        for choice in ["used", "remaining", "server"] {
            context.evaluateScript("elements.usageDisplay.value = '\(choice)'; changeUsageDisplay();")
            #expect(context.evaluateScript("storedUsageDisplay()")?.toString() == choice)
        }
        #expect(context.evaluateScript("saved[usageDisplayKey] === undefined")?.toBool() == true)
        #expect(context.evaluateScript("saved['codexbar.dashboardToken']")?.toString() == "synthetic")
        #expect(context.evaluateScript("saved['codexbar.lastSnapshot']")?.toString() == "null")
        context.evaluateScript("""
        renderSnapshot(fixture);
        fixture.host.usageBarsShowUsed = true;
        renderSnapshot(fixture);
        const rendered = renderWindow({usedPercent:25});
        """)
        #expect(context.evaluateScript("recordedText(rendered)[0]")?.toString() == "Usage · 25% used")
    }

    @Test(arguments: ["used", "remaining", "server"], [false, true])
    func `browser choice survives reload with an older cached snapshot`(choice: String, hasHost: Bool) throws {
        let storage = """
        localStorage.getItem = key => saved[key] ?? null;
        localStorage.setItem = (key, value) => saved[key] = value;
        localStorage.removeItem = key => delete saved[key];
        """
        let context = try self.recordingContext(storageSetup: "const saved = {};\n" + storage)
        context.evaluateScript("""
        if (\(hasHost)) delete fixture.host.usageBarsShowUsed;
        else delete fixture.host;
        for (const provider of fixture.providers) {
          for (const window of provider.windows || []) delete window.remainingPercent;
          for (const account of provider.accounts || []) {
            for (const window of account.windows || []) delete window.remainingPercent;
          }
        }
        persistSnapshot(fixture);
        elements.usageDisplay.value = '\(choice)';
        changeUsageDisplay();
        """)
        #expect(context.exception == nil)
        let savedJSON = try #require(context.evaluateScript("JSON.stringify(saved)")?.toString())
        let reloaded = try self.recordingContext(storageSetup: "const saved = \(savedJSON);\n" + storage)
        #expect(reloaded.evaluateScript("elements.usageDisplay.value")?.toString() == choice)
        #expect(reloaded.evaluateScript("state.forceStale")?.toBool() == true)
        #expect(reloaded.evaluateScript(
            "recordedNodes(elements.providers).filter(node => node.className === 'fill')" +
                ".map(node => node.style.width)")?.toArray() as? [String] ==
            (choice == "used" ? ["20%", "40%", "70%", "10%"] : ["80%", "60%", "30%", "90%"]))
        #expect(reloaded.evaluateScript("recordedText(elements.providers).some(text => text.includes('20% used'))")?
            .toBool() == (choice == "used"))
        #expect(reloaded.evaluateScript("recordedText(elements.providers).some(text => text.includes('80% left'))")?
            .toBool() == (choice != "used"))
    }

    @Test
    func `usage display control is labeled and bundled without external resources`() {
        #expect(self.html.contains(#"<label for="usage-display">Usage display</label>"#))
        #expect(self.html.contains(#"<option value="server">Follow server</option>"#))
        #expect(self.html.contains(#"<option value="used">Used</option>"#))
        #expect(self.html.contains(#"<option value="remaining">Remaining</option>"#))
        #expect(!self.html.contains("<script src="))
        #expect(!self.html.contains(#"rel="stylesheet""#))
    }

    @Test
    func `unavailable storage defaults to server and allows a temporary override`() throws {
        let context = try self.recordingContext(storageSetup: """
        for (const method of ['getItem', 'setItem', 'removeItem']) {
          localStorage[method] = () => { throw new Error('Storage unavailable'); };
        }
        """)
        #expect(context.evaluateScript("state.usageDisplay")?.toString() == "server")
        context.evaluateScript("fixture.host.usageBarsShowUsed = false; renderSnapshot(fixture);")
        for choice in ["used", "remaining", "server"] {
            context.evaluateScript("elements.usageDisplay.value = '\(choice)'; changeUsageDisplay();")
            #expect(context.exception == nil)
            #expect(context.evaluateScript("state.usageDisplay")?.toString() == choice)
            #expect(context.evaluateScript(
                "recordedNodes(elements.providers).find(node => node.className === 'fill').style.width")?
                .toString() == (choice == "used" ? "20%" : "80%"))
        }
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

    @Test(arguments: [false, true], [0, 9876])
    func `expanded Codex credits stay on the selected account only`(
        activeSecond: Bool, remaining: Int) throws
    {
        let context = try self.recordingContext()
        context.evaluateScript("""
        fixture.providers[0].id = "codex";
        fixture.providers[0].name = "Codex";
        fixture.providers[0].credits.remaining = \(remaining);
        fixture.providers[0].accounts[0].active = false;
        fixture.providers[0].accounts[1].active = \(activeSecond);
        renderSnapshot(fixture);
        const cards = recordedNodes(elements.providers).filter(n => n.tagName === 'article');
        """)
        #expect(context.exception == nil)
        let selected = activeSecond ? 1 : 0
        let balance = try #require(context.evaluateScript("amount(\(remaining)) + ' credits'")?.toString())
        for index in 0..<2 {
            let text = try #require(context.evaluateScript("recordedText(cards[\(index)])")?.toArray() as? [String])
            #expect(text.contains("Remaining") == (index == selected))
            #expect(text.contains(balance) == (index == selected))
        }
        let allText = try #require(context.evaluateScript("recordedText(elements.providers)")?.toArray() as? [String])
        #expect(allText.filter { $0 == balance }.count == 1)
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

    private func recordingContext(
        costJSON: String? = nil,
        locale: String? = nil,
        storageSetup: String? = nil) throws -> JSContext
    {
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
        if let storageSetup { context.evaluateScript(storageSetup) }
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
    func `web ui renders account cards in titled groups for multi account providers`() throws {
        let context = try self.recordingContext()
        context.evaluateScript("renderSnapshot(fixture);")
        #expect(context.exception == nil)
        let text = try #require(context.evaluateScript("recordedText(elements.providers)")?.toArray() as? [String])
        #expect(text.contains("Claude accounts"))
        #expect(text.contains("Synthetic adapter note"))
        #expect(context.evaluateScript(
            "recordedNodes(elements.providers).filter(node => node.tagName === 'article').length")?.toInt32() == 3)
    }

    @Test
    func `account cards preserve projected labels before falling back to email`() throws {
        let start = try #require(self.html.range(of: "function renderAccountCard("))
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
