import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIOutputTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `OpenRouter text and JSON retain independent cap and balance`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await OpenRouterLimitTestSupport.snapshot(engine: engine)
        let text = CLIRenderer.renderText(
            provider: .openrouter,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "OpenRouter (api)", status: nil, useColor: false, resetStyle: .countdown),
            now: OpenRouterLimitTestSupport.now)
        #expect(text.contains("API key limit: $30.00 · Spending cap, not balance"))
        #expect(text.contains("API key remaining: $30.00"))
        #expect(text.contains("Balance: $1.90"))
        #expect(text.contains("100% left"))
        #expect(!text.contains("API key budget"))

        let data = try JSONEncoder().encode(snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let details = try #require(json["details"] as? [[String: Any]])
        let rows = try #require(details[1]["rows"] as? [[String: String]])
        #expect(rows[0] == [
            "label": "API key limit", "value": "$30.00", "secondaryValue": "Spending cap, not balance",
        ])
        #expect(rows[1] == ["label": "API key remaining", "value": "$30.00"])
        #expect((json["primary"] as? [String: Double]) == ["usedPercent": 0])
        #expect(Set(json.keys) == [
            "primary", "secondary", "tertiary", "details", "updatedAt", "identity", "loginMethod",
        ])
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.details == snapshot.details)
        #expect(decoded.primary?.usedPercent == 0)
        #expect(decoded.identity?.loginMethod == "Balance: $1.90")
    }

    @Test
    func `output preferences json only forces JSON`() {
        let output = CLIOutputPreferences.from(argv: ["--json-only"])
        #expect(output.jsonOnly == true)
        #expect(output.format == .json)
    }

    @Test
    func `argv bootstrap preferences recognize toon before Commander parsing`() {
        // This is the scanner CLIEntry uses to render a Program.resolve parse failure (an unknown
        // option, before ParsedValues exists), so it has to recognize --format toon independently
        // of the post-parse resolveUsageOutputPreferences path.
        let spaceForm = CLIOutputPreferences.from(argv: ["usage", "--format", "toon"])
        #expect(spaceForm.toonRequested)
        #expect(spaceForm.format == .json)
        #expect(spaceForm.usesJSONOutput)

        let equalsForm = CLIOutputPreferences.from(argv: ["usage", "--format=toon"])
        #expect(equalsForm.toonRequested)
        #expect(equalsForm.format == .json)

        let notRequested = CLIOutputPreferences.from(argv: ["usage", "--format", "json"])
        #expect(!notRequested.toonRequested)
        #expect(notRequested.format == .json)
    }

    @Test
    func `explicit toon format wins over a json shortcut in argv bootstrap`() {
        let toonThenJSON = CLIOutputPreferences.from(argv: ["usage", "--format", "toon", "--json"])
        #expect(toonThenJSON.toonRequested)
        #expect(toonThenJSON.format == .json)

        let jsonThenToon = CLIOutputPreferences.from(argv: ["usage", "--json", "--format", "toon"])
        #expect(jsonThenToon.toonRequested)
        #expect(jsonThenToon.format == .json)
    }

    @Test
    func `a later explicit format overrides an earlier toon request`() {
        let output = CLIOutputPreferences.from(argv: ["usage", "--format", "toon", "--format", "json"])
        #expect(!output.toonRequested)
        #expect(output.format == .json)
    }

    @Test
    func `parse failure argv bootstrap matches explicit format precedence for toon plus json`() {
        let output = CLIOutputPreferences.from(argv: ["usage", "--format", "toon", "--json", "--bogus"])
        #expect(output.toonRequested)
        #expect(output.format == .json)
    }

    @Test
    func `toon is recognized for usage and ignored for every other command`() {
        let values = ParsedValues(positional: [], options: ["format": ["toon"]], flags: [])

        let usage = CodexBarCLI.resolveUsageOutputPreferences(from: values)
        #expect(usage.toonRequested)
        #expect(usage.format == .json)

        // cost, cache, config, hooks, and diagnose share this constructor and advertise only
        // `text | json`, so `toon` has to stay an unrecognized value there instead of meaning JSON.
        let other = CLIOutputPreferences.from(values: values)
        #expect(!other.toonRequested)
        #expect(other.format == .text)
        #expect(!other.usesJSONOutput)
    }

    @Test
    func `toon does not change the decoded format of non usage commands`() {
        let toonOnly = ParsedValues(positional: [], options: ["format": ["toon"]], flags: [])
        #expect(CodexBarCLI._decodeFormatForTesting(from: toonOnly) == .text)

        // An unrecognized --format still loses to nothing, so --json keeps deciding the format.
        let toonWithJSONShortcut = ParsedValues(positional: [], options: ["format": ["toon"]], flags: ["json"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: toonWithJSONShortcut) == .json)

        // An unrelated unsupported value behaves identically, which is the pre-TOON contract.
        let unsupported = ParsedValues(positional: [], options: ["format": ["xml"]], flags: [])
        #expect(CodexBarCLI._decodeFormatForTesting(from: unsupported) == .text)
    }

    @Test
    func `argv bootstrap only recognizes toon for the usage command`() {
        for command in ["cost", "cache", "config", "hooks", "diagnose", "guard", "serve"] {
            let output = CLIOutputPreferences.from(argv: [command, "--format", "toon"])
            #expect(!output.toonRequested, "\(command) must not accept --format toon")
            #expect(output.format == .text, "\(command) must keep its pre-TOON default format")

            let equalsForm = CLIOutputPreferences.from(argv: [command, "--format=toon", "--json"])
            #expect(!equalsForm.toonRequested, "\(command) must not accept --format=toon")
            #expect(equalsForm.format == .json, "\(command) must still honor --json")
        }

        // `effectiveArgv` routes a bare `codexbar --format toon` to the implicit usage command.
        let implicitUsage = CLIOutputPreferences.from(argv: ["--format", "toon"])
        #expect(implicitUsage.toonRequested)
        #expect(implicitUsage.format == .json)
    }

    @Test
    func `cli error payload is JSON array`() throws {
        let payload = CodexBarCLI.makeCLIErrorPayload(
            message: "Nope",
            code: .failure,
            kind: .args,
            pretty: false)
        #expect(payload != nil)
        let data = payload?.data(using: .utf8) ?? Data()
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        #expect(json?.isEmpty == false)
        let first = json?.first as? [String: Any]
        #expect(first?["provider"] as? String == "cli")
        let error = first?["error"] as? [String: Any]
        #expect(error?["message"] as? String == "Nope")
    }

    @Test
    func `exit omits generic error when command already emitted payload`() {
        #expect(!CodexBarCLI.shouldPrintExitError(code: .success, message: nil))
        #expect(!CodexBarCLI.shouldPrintExitError(code: .failure, message: nil))
        #expect(CodexBarCLI.shouldPrintExitError(code: .failure, message: "Nope"))
    }

    @Test
    func `text renderer includes deepgram usage metrics`() {
        let deepgram = UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [.makeSection(title: "Usage summary", rows: [
                .makeRow(label: "Requests", value: "42"),
                .makeRow(label: "Audio", value: "12.5 hours", secondaryValue: "14 billable hours"),
                .makeRow(label: "Agent hours", value: "1.2"),
                .makeRow(label: "Tokens", value: "150"),
                .makeRow(label: "TTS characters", value: "1,200"),
                .makeRow(label: "Period", value: "2026-05-10 to 2026-05-17"),
            ])],
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: ProviderIdentitySnapshot(
                providerID: .deepgram,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Project: project-123"))
        let text = CLIRenderer.renderText(
            provider: .deepgram,
            snapshot: deepgram,
            credits: nil,
            context: RenderContext(
                header: "Deepgram (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Requests: 42"))
        #expect(text.contains("Audio: 12.5 hours · 14 billable hours"))
        #expect(text.contains("Agent hours: 1.2"))
        #expect(text.contains("Tokens: 150"))
        #expect(text.contains("TTS characters: 1,200"))
        #expect(text.contains("Period: 2026-05-10 to 2026-05-17"))
    }

    @Test
    func `text renderer includes amp credits without free tier usage`() {
        let snapshot = AmpUsageSnapshot(
            freeQuota: nil,
            freeUsed: nil,
            hourlyReplenishment: nil,
            windowHours: nil,
            individualCredits: 25.64,
            workspaceBalances: [
                AmpWorkspaceBalance(name: "Alpha Team", remaining: 1234.56),
            ],
            accountEmail: "paid@example.com",
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot()

        let text = CLIRenderer.renderText(
            provider: .amp,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Amp (cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Individual credits: $25.64"))
        #expect(text.contains("Workspace Alpha Team: $1,234.56"))
        #expect(text.contains("Account: paid@example.com"))
        #expect(!text.contains("Amp Free:"))
    }

    @Test
    func `text renderer labels amp subscription pools`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AmpUsageSnapshot(
            freeQuota: nil,
            freeUsed: nil,
            hourlyReplenishment: nil,
            windowHours: nil,
            updatedAt: now,
            subscription: AmpSubscriptionUsage(
                plan: "Megawatt",
                otherUsedPercent: 3,
                orbUsedPercent: 0,
                resetsAt: now.addingTimeInterval(29 * 24 * 60 * 60),
                resetDescription: "renews in 29 days"))
            .toUsageSnapshot(now: now)

        let text = CLIRenderer.renderText(
            provider: .amp,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Amp (cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(text.contains("Other usage:"))
        #expect(text.contains("Orb usage:"))
        #expect(!text.contains("Amp Free:"))
        #expect(!text.contains("Balance:"))
    }

    @Test
    func `text renderer shows mimo balance without quota or reset text`() {
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            cashBalance: 20,
            giftBalance: 5.51,
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot()

        let text = CLIRenderer.renderText(
            provider: .mimo,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Xiaomi MiMo (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Balance: $25.51 (Paid: $20.00 / Granted: $5.51)"))
        #expect(!text.contains("100%"))
        #expect(!text.contains("Resets"))
        #expect(!text.contains("Plan: Balance"))
    }

    @Test
    func `text renderer shows mimo token credits and balance`() {
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            planCode: "standard",
            tokenUsed: 10,
            tokenLimit: 100,
            tokenPercent: 0.1,
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot()

        let text = CLIRenderer.renderText(
            provider: .mimo,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Xiaomi MiMo (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Credits: 90% left"))
        #expect(text.contains("Balance: $25.51"))
        #expect(text.contains("Plan: Standard"))
        #expect(!text.contains("Window: 100%"))
    }

    @Test
    func `text renderer preserves compact mimo local summary casing`() {
        let summary = "Local · 1.5k total · 42 sessions · stale 34d"
        let snapshot = MiMoUsageSnapshot(
            balance: 0,
            currency: "",
            planCode: summary,
            updatedAt: Date(timeIntervalSince1970: 0))
            .toUsageSnapshot(includeBalance: false)

        let text = CLIRenderer.renderText(
            provider: .mimo,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Xiaomi MiMo (local)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(CLIRenderer.planBadgeText(provider: .mimo, snapshot: snapshot) == summary)
        #expect(text.contains("Plan: \(summary)"))
        #expect(!text.contains("Stale 34D"))
    }

    @Test
    func `text renderer includes Claude extra usage balance`() {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 5,
                limit: 20,
                currencyCode: "USD",
                period: "Monthly cap",
                balance: 100,
                updatedAt: now),
            updatedAt: now)

        let text = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Claude (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Extra usage balance: $100.00"))
    }

    @Test
    func `text renderer does not show zero cost for Claude balance only snapshot`() {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage",
                balance: 100,
                updatedAt: now),
            updatedAt: now)

        let text = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Claude (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Extra usage balance: $100.00"))
        #expect(!text.contains("Cost: 0.0 / 0.0"))
    }
}
