import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

// swiftlint:disable:next type_body_length
struct CLISnapshotTests {
    @Test
    func `renders Gemini paid plan without changing acronym casing`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .gemini,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Gemini Code Assist in Google One AI Pro")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .gemini,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Gemini",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(CLIRenderer.planBadgeText(provider: .gemini, snapshot: snapshot) ==
            "Gemini Code Assist in Google One AI Pro")
        #expect(output.contains("Plan: Gemini Code Assist in Google One AI Pro"))
        #expect(!output.contains("Google One Ai Pro"))
    }

    @Test
    func `renders Factory token rate billing with time window labels`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: .init(usedPercent: 50, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .factory,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Droid (factory)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("5-hour: 88% left"))
        #expect(output.contains("Weekly: 75% left"))
        #expect(output.contains("Monthly: 50% left"))
        #expect(!output.contains("Standard:"))
        #expect(!output.contains("Premium:"))
    }

    @Test
    func `renders Factory legacy billing with pool labels`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .factory,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Droid (factory)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Standard: 88% left"))
        #expect(output.contains("Premium: 75% left"))
        #expect(!output.contains("5-hour:"))
        #expect(!output.contains("Monthly:"))
    }

    @Test
    func `renders text snapshot for codex`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: "today at 3:00 PM"),
            secondary: .init(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: "Fri at 9:00 AM"),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: CreditsSnapshot(remaining: 42, events: [], updatedAt: Date()),
            context: RenderContext(
                header: "Codex 1.2.3 (codex-cli)",
                status: ProviderStatusPayload(
                    indicator: .minor,
                    description: "Degraded performance",
                    updatedAt: Date(timeIntervalSince1970: 0),
                    url: "https://status.example.com"),
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Codex 1.2.3 (codex-cli)"))
        #expect(output.contains("Status: Partial outage – Degraded performance"))
        #expect(output.contains("Codex"))
        #expect(output.contains("Session: 88% left"))
        #expect(output.contains("Weekly: 75% left"))
        #expect(output.contains("Credits: 42"))
        #expect(output.contains("Account: user@example.com"))
        #expect(output.contains("Plan: Pro 20x"))
    }

    @Test
    func `renders Codex limit reset credits`() {
        let now = Date()
        let expiresAt = now.addingTimeInterval(7200)
        let resetCredits = CodexRateLimitResetCreditsSnapshot(
            credits: [
                CodexRateLimitResetCredit(
                    id: "credit-1",
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: Date(timeIntervalSince1970: 0),
                    expiresAt: expiresAt,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil),
                CodexRateLimitResetCredit(
                    id: "expired-credit",
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: Date(timeIntervalSince1970: 0),
                    expiresAt: now,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil),
            ],
            availableCount: 99,
            updatedAt: Date(timeIntervalSince1970: 0))
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            codexResetCredits: resetCredits,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Codex (oauth)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("Limit Reset Credits: 1 available"))
        #expect(output.contains("Next reset credit expires"))
    }

    @Test
    func `renders Codex prolite plan with multiplier display name`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "prolite")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: "today at 3:00 PM"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 1.2.3 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Plan: Pro 5x"))
        #expect(!output.contains("Plan: Pro Lite"))
        #expect(!output.contains("Plan: Prolite"))
    }

    @Test
    func `renders Codex plan only limits as unavailable`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 1.2.3 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Limits: not available"))
        #expect(output.contains("Account: user@example.com"))
        #expect(output.contains("Plan: Pro 20x"))
        #expect(!output.contains("Session:"))
        #expect(!output.contains("Weekly:"))
    }

    @Test
    func `renders text snapshot for claude without weekly`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 2, windowMinutes: nil, resetsAt: nil, resetDescription: "3pm (Europe/Vienna)"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.69 (claude)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Session: 98% left"))
        #expect(!output.contains("Weekly:"))
    }

    @Test
    func `renders Claude Max multiplier without uppercasing x`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Claude Max 5x")
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 2, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Claude (oauth)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Plan: Claude Max 5x"))
        #expect(!output.contains("Plan: Claude Max 5X"))
    }

    @Test
    func `renders warp unlimited as detail not reset`() {
        let meta = ProviderDescriptorRegistry.descriptor(for: .warp).metadata
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "Unlimited"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            identity: ProviderIdentitySnapshot(
                providerID: .warp,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        let output = CLIRenderer.renderText(
            provider: .warp,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Warp 0.0.0 (warp)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("\(meta.sessionLabel): 100% left"))
        #expect(!output.contains("Resets Unlimited"))
        #expect(output.contains("Unlimited"))
    }

    @Test
    func `renders warp credits as detail and reset as date`() {
        let meta = ProviderDescriptorRegistry.descriptor(for: .warp).metadata
        let now = Date(timeIntervalSince1970: 0)
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 10,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: "10/100 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .warp,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        let output = CLIRenderer.renderText(
            provider: .warp,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Warp 0.0.0 (warp)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("\(meta.sessionLabel): 90% left"))
        #expect(output.contains("Resets"))
        #expect(output.contains("10/100 credits"))
        #expect(!output.contains("Resets 10/100 credits"))
    }

    @Test
    func `renders crof dollar balance as detail not reset`() {
        let meta = ProviderDescriptorRegistry.descriptor(for: .crof).metadata
        let snap = CrofUsageSnapshot(
            credits: 9.9999,
            requestsPlan: 1000,
            usableRequests: 998,
            updatedAt: Date(timeIntervalSince1970: 0)).toUsageSnapshot()

        let output = CLIRenderer.renderText(
            provider: .crof,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Crof",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("\(meta.sessionLabel): 99% left"))
        #expect(output.contains("\(meta.weeklyLabel): 100% left"))
        #expect(output.contains("$9.99"))
        #expect(!output.contains("Resets $9.99"))
    }

    @Test
    func `renders qoder reset and credit total separately`() {
        let meta = ProviderDescriptorRegistry.descriptor(for: .qoder).metadata
        let now = Date(timeIntervalSince1970: 0)
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: "125 / 500 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        let output = CLIRenderer.renderText(
            provider: .qoder,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Qoder",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(output.contains("\(meta.sessionLabel): 75% left"))
        #expect(output.contains("Resets in 1h"))
        #expect(output.contains("125 / 500 credits"))
        #expect(!output.contains("Resets 125 / 500 credits"))
    }

    @Test
    func `renders kilo plan activity and fallback note`() {
        let now = Date(timeIntervalSince1970: 0)
        let identity = ProviderIdentitySnapshot(
            providerID: .kilo,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Kilo Pass Pro · Auto top-up: visa")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: "40/100 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .kilo,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Kilo (cli)",
                status: nil,
                useColor: false,
                resetStyle: .absolute,
                notes: ["Using CLI fallback"]))

        #expect(output.contains("Credits: 60% left"))
        #expect(output.contains("40/100 credits"))
        #expect(!output.contains("Resets 40/100 credits"))
        #expect(output.contains("Plan: Kilo Pass Pro"))
        #expect(output.contains("Activity: Auto top-up: visa"))
        #expect(output.contains("Note: Using CLI fallback"))
    }

    @Test
    func `renders kilo zero total edge state as detail`() {
        let now = Date(timeIntervalSince1970: 0)
        let snap = KiloUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 0,
            creditsRemaining: 0,
            planName: "Kilo Pass Pro",
            autoTopUpEnabled: true,
            autoTopUpMethod: "visa",
            updatedAt: now).toUsageSnapshot()

        let output = CLIRenderer.renderText(
            provider: .kilo,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Kilo (api)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Credits: 0% left"))
        #expect(output.contains("0/0 credits"))
        #expect(!output.contains("Resets 0/0 credits"))
    }

    @Test
    func `renders kilo auto top up only as activity without plan`() {
        let now = Date(timeIntervalSince1970: 0)
        let identity = ProviderIdentitySnapshot(
            providerID: .kilo,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Auto top-up: off")
        let snap = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .kilo,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Kilo (cli)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Activity: Auto top-up: off"))
        #expect(!output.contains("Plan: Auto top-up: off"))
    }

    @Test
    func `renders pace line when weekly has reset`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: nil,
            secondary: .init(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("Pace:"))
    }

    @Test
    func `configured work days affect weekly text and JSON pace`() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let resetsAt = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 14)))
        let now = resetsAt.addingTimeInterval(-72 * 60 * 60)
        let snap = UsageSnapshot(
            primary: nil,
            secondary: .init(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown,
                weeklyWorkDays: 5),
            now: now)
        #expect(output.contains("Pace: On pace | Expected 60% used | Lasts until reset"))

        let pace = try #require(CLIRenderer.providerPacePayload(
            provider: .codex,
            snapshot: snap,
            weeklyWorkDays: 5,
            now: now)?.secondary)
        #expect(pace.expectedUsedPercent == 60)
        #expect(pace.summary == "On pace | Expected 60% used | Lasts until reset")
    }

    @Test
    func `renders Ollama weekly pace line when weekly window has reset`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(4 * 3600),
                resetDescription: nil),
            secondary: .init(
                usedPercent: 23,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .ollama,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Ollama (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("Weekly: 77% left"))
        #expect(output.contains("Pace: 6% in reserve | Expected 29% used | Lasts until reset"))
        #expect(!output.contains("1.5× headroom"))
    }

    @Test
    func `hides Ollama weekly pace when weekly duration is missing`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: nil,
            secondary: .init(
                usedPercent: 23,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .ollama,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Ollama (web)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("Weekly: 77% left"))
        #expect(!output.contains("Pace:"))
    }

    @Test
    func `renders session pace line when session window has reset`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(output.contains("Session: 80% left"))
        // 2h remaining of a 5h window => 3h elapsed => 60% expected; even rate easily lasts to reset.
        #expect(output.contains("Pace: 40% in reserve | Expected 60% used | Lasts until reset | 1.5× headroom"))
    }

    @Test
    func `renders Claude session pace using five hour default window`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.69 (claude)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        // windowMinutes is nil, so the 5-hour (300 minute) session default must drive the pace.
        #expect(output.contains("Pace: 40% in reserve | Expected 60% used | Lasts until reset"))
        #expect(!output.contains("1.5× headroom"))
    }

    @Test
    func `renders session pace deficit with run out estimate`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        // 1h elapsed of a 5h window => 20% expected vs 50% used => burning ahead of pace.
        // Session mirrors the GUI's "Projected empty" wording (weekly uses "Runs out").
        #expect(output.contains("Pace: 30% in deficit | Expected 20% used | Projected empty in"))
        #expect(!output.contains("Runs out"))
    }

    @Test
    func `renders session pace on track and lasts until reset`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Exactly halfway through a 5h window with 50% used => On pace (delta 0); the even rate
        // means the quota lasts precisely to the reset.
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2.5 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(output.contains("Pace: On pace | Expected 50% used | Lasts until reset"))
    }

    @Test
    func `hides session pace for unsupported provider`() {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .zai,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "z.ai 0.0.0 (zai)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(!output.contains("Pace:"))
    }

    @Test
    func `hides session pace for non-session primary window`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Claude with no 5-hour data falls a 7-day window back into `primary`; it must not be
        // paced as a "Session" (that would print "Projected empty …" over a weekly window).
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.69 (claude)",
                status: nil,
                useColor: false,
                resetStyle: .countdown),
            now: now)

        #expect(!output.contains("Pace:"))
        #expect(CLIRenderer.providerPacePayload(provider: .claude, snapshot: snap, now: now) == nil)
    }

    @Test
    func `renders JSON payload`() throws {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 10, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: "1.2.3",
            source: "codex-cli",
            status: ProviderStatusPayload(
                indicator: .none,
                description: nil,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_010),
                url: "https://status.example.com"),
            usage: snap,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode JSON payload")
            return
        }

        #expect(json.contains("\"provider\":\"codex\""))
        #expect(json.contains("\"version\":\"1.2.3\""))
        #expect(json.contains("\"status\""))
        #expect(json.contains("status.example.com"))
        #expect(json.contains("\"primary\""))
        #expect(json.contains("\"windowMinutes\":300"))
        #expect(json.contains("1700000000"))
    }

    @Test
    func `json pace rounds derived numbers to match usage precision`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 13000s elapsed of an 18000s (300m) window => 72.22% expected; used 79 => +6.78 deficit;
        // projected empty in ~3455.7s. Derived fields must be emitted as whole numbers (no float noise).
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 79,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(5000),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "codex-cli",
            status: nil,
            usage: snap,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil,
            pace: CLIRenderer.providerPacePayload(provider: .codex, snapshot: snap, now: now))

        let data = try JSONEncoder().encode(payload)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let primary = try #require((root["pace"] as? [String: Any])?["primary"] as? [String: Any])

        #expect(primary["expectedUsedPercent"] as? Double == 72)
        #expect(primary["deltaPercent"] as? Double == 7)
        #expect(primary["etaSeconds"] as? Double == 3456)
        // actualUsedPercent is not emitted; consumers read usage.primary.usedPercent.
        #expect(primary["actualUsedPercent"] == nil)
    }

    @Test
    func `json payload includes session and weekly pace with distinct wording`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = UsageSnapshot(
            // 1h elapsed of a 5h window => 20% expected vs 50% used => deficit, runs out in 1h.
            primary: .init(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            // 5d elapsed of a 7d window => ~71% expected vs 90% used => deficit, runs out before reset.
            secondary: .init(
                usedPercent: 90,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: "1.2.3",
            source: "codex-cli",
            status: nil,
            usage: snap,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil,
            pace: CLIRenderer.providerPacePayload(provider: .codex, snapshot: snap, now: now))

        let data = try JSONEncoder().encode(payload)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pace = try #require(root["pace"] as? [String: Any])

        let primary = try #require(pace["primary"] as? [String: Any])
        #expect(primary["stage"] as? String == "farAhead")
        #expect(primary["expectedUsedPercent"] as? Double == 20)
        #expect(primary["deltaPercent"] as? Double == 30)
        #expect(primary["willLastToReset"] as? Bool == false)
        #expect(primary["etaSeconds"] as? Double == 3600)
        #expect((primary["summary"] as? String)?
            .contains("30% in deficit | Expected 20% used | Projected empty in") == true)
        // actualUsedPercent is redundant with usage.usedPercent and is not emitted;
        // runOutProbability is never set by the CLI, so both keys are omitted.
        #expect(primary["actualUsedPercent"] == nil)
        #expect(primary["runOutProbability"] == nil)

        let secondary = try #require(pace["secondary"] as? [String: Any])
        #expect(secondary["stage"] as? String == "farAhead")
        #expect((secondary["summary"] as? String)?.contains("Runs out in") == true)
        #expect((secondary["summary"] as? String)?.contains("Projected empty") == false)
    }

    @Test
    func `json omits pace when not applicable`() throws {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        // z.ai is not a session/weekly pace provider, so no pace should be emitted.
        let payload = ProviderPayload(
            provider: .zai,
            account: nil,
            version: nil,
            source: "zai",
            status: nil,
            usage: snap,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil,
            pace: CLIRenderer.providerPacePayload(provider: .zai, snapshot: snap, now: now))

        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"pace\""))
    }

    @Test
    func `json includes only session pace when weekly window missing`() throws {
        let now = Date()
        let snap = UsageSnapshot(
            primary: .init(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now)

        let payload = ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "codex-cli",
            status: nil,
            usage: snap,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil,
            pace: CLIRenderer.providerPacePayload(provider: .codex, snapshot: snap, now: now))

        let data = try JSONEncoder().encode(payload)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pace = try #require(root["pace"] as? [String: Any])
        #expect(pace["primary"] is [String: Any])
        #expect(pace["secondary"] == nil)
    }

    @Test
    func `encodes JSON with secondary null when missing`() throws {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snap)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode JSON payload")
            return
        }

        #expect(json.contains("\"secondary\":null"))
    }

    @Test
    func `parses output format`() {
        #expect(OutputFormat(argument: "json") == .json)
        #expect(OutputFormat(argument: "TEXT") == .text)
        #expect(OutputFormat(argument: "invalid") == nil)
    }

    @Test
    func `defaults to usage when no command provided`() {
        #expect(CodexBarCLI.effectiveArgv([]) == ["usage"])
        #expect(CodexBarCLI.effectiveArgv(["--format", "json"]).first == "usage")
        #expect(CodexBarCLI.effectiveArgv(["usage", "--format", "json"]).first == "usage")
    }

    @Test
    func `status line is last and colored when TTY`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .claude,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Claude Code 2.0.58 (claude)",
                status: ProviderStatusPayload(
                    indicator: .critical,
                    description: "Major outage",
                    updatedAt: nil,
                    url: "https://status.claude.com"),
                useColor: true,
                resetStyle: .absolute))

        let lines = output.split(separator: "\n")
        #expect(lines.last?.contains("Status: Critical issue – Major outage") == true)
        #expect(output.contains("\u{001B}[31mStatus")) // red for critical
    }

    @Test
    func `output has ansi when TTY even without status`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: true,
                resetStyle: .absolute))

        #expect(output.contains("\u{001B}["))
    }

    @Test
    func `tty output colors header and usage`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 95, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 80, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.0.0 (codex-cli)",
                status: nil,
                useColor: true,
                resetStyle: .absolute))

        #expect(output.contains("\u{001B}[1;95m== Codex 0.0.0 (codex-cli) ==\u{001B}[0m"))
        #expect(output.contains("Session: \u{001B}[31m5% left\u{001B}[0m")) // red <10% left
        #expect(output.contains("Weekly: \u{001B}[33m20% left\u{001B}[0m")) // yellow <25% left
    }

    @Test
    func `status line is plain when no TTY`() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "pro")
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)

        let output = CLIRenderer.renderText(
            provider: .codex,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Codex 0.6.0 (codex-cli)",
                status: ProviderStatusPayload(
                    indicator: .none,
                    description: "Operational",
                    updatedAt: nil,
                    url: "https://status.openai.com/"),
                useColor: false,
                resetStyle: .absolute))

        #expect(!output.contains("\u{001B}["))
        #expect(output.contains("Status: Operational – Operational"))
    }

    @Test
    func `renders 5-hour tertiary row for zai`() {
        let snap = UsageSnapshot(
            primary: .init(usedPercent: 9, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: .init(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: .init(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CLIRenderer.renderText(
            provider: .zai,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "z.ai 0.0.0 (zai)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("5-hour:"))
        #expect(output.contains("Tokens:"))
        #expect(output.contains("MCP:"))
    }

    @Test
    func `devin overage balance without primary window omits generic cost line`() {
        let snap = UsageSnapshot(
            primary: nil,
            secondary: .init(usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 48.0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 0)),
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CLIRenderer.renderText(
            provider: .devin,
            snapshot: snap,
            credits: nil,
            context: RenderContext(
                header: "Devin (devin)",
                status: nil,
                useColor: false,
                resetStyle: .absolute))
        #expect(output.contains("Extra usage: $48.00"))
        #expect(!output.contains("Cost:"))
        #expect(!output.contains(" / 0.0"))
    }
}
