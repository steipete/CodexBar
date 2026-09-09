import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Covers `codexbar usage --provider antigravity` and the shared `cards` metric path rendering
/// Antigravity's per-bucket quota-summary lanes (Sources/CodexBarCore/Providers/Antigravity/
/// AntigravityStatusProbe.swift) instead of the collapsed legacy "Gemini Models"/"Claude and GPT"
/// lanes, mirroring what the menu bar already does via `hasAntigravityQuotaSummaryWindows`
/// (Sources/CodexBar/MenuCardView+ModelHelpers.swift). Idle families drop out of both surfaces the
/// same way the widget and the web dashboard drop them.
struct AntigravityCLILaneParityTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func quotaSummarySnapshot(
        geminiSessionPercent: Double,
        geminiWeeklyPercent: Double,
        thirdPartySessionPercent: Double,
        includeUnknownThirdPartyLane: Bool = false) -> UsageSnapshot
    {
        let geminiSession = RateWindow(
            usedPercent: geminiSessionPercent,
            windowMinutes: 300,
            resetsAt: Self.now.addingTimeInterval(34 * 60),
            resetDescription: nil)
        let geminiWeekly = RateWindow(
            usedPercent: geminiWeeklyPercent,
            windowMinutes: 10080,
            resetsAt: Self.now.addingTimeInterval((2 * 24 + 15) * 60 * 60),
            resetDescription: nil)
        let thirdPartySession = RateWindow(
            usedPercent: thirdPartySessionPercent,
            windowMinutes: 300,
            resetsAt: Self.now.addingTimeInterval(5 * 60 * 60),
            resetDescription: nil)

        var extras = [
            NamedRateWindow(
                id: "antigravity-quota-summary-gemini-5h",
                title: "Gemini 5-hour",
                window: geminiSession),
            NamedRateWindow(
                id: "antigravity-quota-summary-gemini-weekly",
                title: "Gemini weekly",
                window: geminiWeekly),
            NamedRateWindow(
                id: "antigravity-quota-summary-3p-5h",
                title: "Claude/GPT 5-hour",
                window: thirdPartySession),
        ]
        if includeUnknownThirdPartyLane {
            // The probe reports reset metadata before it knows usage; such a lane carries usageKnown: false.
            extras.append(NamedRateWindow(
                id: "antigravity-quota-summary-3p-weekly",
                title: "Claude/GPT weekly",
                window: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                usageKnown: false))
        }

        return UsageSnapshot(
            // The probe synthesizes worst-of-family representatives into primary/secondary so legacy
            // consumers stay populated; the CLI must render the extras instead of these.
            primary: geminiSession,
            secondary: thirdPartySession,
            tertiary: nil,
            extraRateWindows: extras,
            updatedAt: Self.now,
            identity: Self.identity())
    }

    private static func unknownSnapshot(includeKnownLane: Bool = false) -> UsageSnapshot {
        let unknown = NamedRateWindow(
            id: "antigravity-quota-summary-gemini-weekly",
            title: "Gemini weekly",
            window: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(7 * 86400),
                resetDescription: nil),
            usageKnown: false)
        let known = NamedRateWindow(
            id: "antigravity-quota-summary-3p-5h",
            title: "Claude/GPT 5-hour",
            window: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil))
        return UsageSnapshot(
            primary: nil,
            secondary: includeKnownLane ? known.window : nil,
            tertiary: nil,
            extraRateWindows: [unknown] + (includeKnownLane ? [known] : []),
            updatedAt: self.now,
            identity: self.identity())
    }

    private static func card(_ snapshot: UsageSnapshot) -> CLICardModel {
        CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .antigravity,
            snapshot: snapshot,
            credits: nil,
            source: "fixture",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: self.now))
    }

    private static func legacyModelQuotasSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 2, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 4, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: self.now,
            identity: self.identity())
    }

    private static func identity() -> ProviderIdentitySnapshot {
        ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: "quota-user@example.com",
            accountOrganization: nil,
            loginMethod: "google ai pro")
    }

    private static func renderContext() -> RenderContext {
        RenderContext(
            header: "Antigravity (cli)",
            status: nil,
            useColor: false,
            resetStyle: .countdown)
    }

    private static func renderedText(_ snapshot: UsageSnapshot) -> String {
        CLIRenderer.renderText(
            provider: .antigravity,
            snapshot: snapshot,
            credits: nil,
            context: self.renderContext(),
            now: self.now)
    }

    private static func cardMetricLabels(_ snapshot: UsageSnapshot) -> [String] {
        CLIRenderer.collectCardMetrics(
            provider: .antigravity,
            snapshot: snapshot,
            resetStyle: .countdown,
            now: self.now)
            .map(\.label)
    }

    @Test(arguments: [false, true])
    func `unknown and disabled first buckets stay unavailable in text and cards`(disabled: Bool) throws {
        var unknown: [String: Any] = [
            "bucketId": "gemini-5h", "displayName": "5-hour", "description": "Fixture session reset",
        ]
        if disabled {
            unknown["disabled"] = true
            unknown["remaining"] = ["remainingFraction": 0.3]
        }
        let known: [String: Any] = [
            "bucketId": "gemini-weekly", "displayName": "weekly", "remaining": ["remainingFraction": 0.96],
        ]
        let payload: [String: Any] = [
            "response": ["groups": [["displayName": "Gemini Models", "buckets": [unknown, known]]]],
        ]
        let parsed = try AntigravityStatusProbe.parseQuotaSummaryResponse(
            JSONSerialization.data(withJSONObject: payload))
        let snapshot = try parsed.toUsageSnapshot()
        #expect(snapshot.extraRateWindows?.first?.usageKnown == false)
        let text = Self.renderedText(snapshot)
        let compact = CLIRenderer.renderCardBodyLines(
            provider: .antigravity,
            snapshot: snapshot,
            credits: nil,
            context: Self.renderContext(),
            includeIdentity: false,
            now: Self.now).joined(separator: "\n")
        for rendered in [text, compact] {
            #expect(rendered.contains("Gemini 5-hour: Unavailable"))
            #expect(rendered.contains("Fixture session reset"))
            #expect(!rendered.contains("100% left"))
            #expect(!rendered.contains("30% left"))
            #expect(rendered.contains("Gemini weekly: 96% left"))
        }
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .antigravity,
            snapshot: snapshot,
            credits: nil,
            source: "cli",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))
        #expect(card.metrics.map { $0.remainingPercent != nil } == [false, true])
        let full = CLICardsRenderer.render(cards: [card], failures: [], terminalWidth: 80, useColor: false)
        #expect(full.split(separator: "\n").first(where: { $0.contains("Gemini 5-hour") })?
            .contains("Unavailable") == true)
        #expect(full.contains("Fixture session reset"))
        #expect(!full.contains("100% left"))
        #expect(!full.contains("30% left"))
        let rows = CLICardsBriefRenderer.makeRows(cards: [card])
        #expect(rows.first?.usedPercent == nil)
        #expect(rows.first?.resetLabel?.contains("Fixture session reset") == true)
        let brief = CLICardsBriefRenderer.render(
            rows: rows, failures: [], terminalWidth: 80, useColor: false, now: Self.now)
        #expect(!brief.contains("%"))
    }

    @Test
    func `quota summary snapshot renders one lane per bucket with no collapsed lane or pace`() {
        let text = Self.renderedText(Self.quotaSummarySnapshot(
            geminiSessionPercent: 2,
            geminiWeeklyPercent: 4,
            thirdPartySessionPercent: 1))

        #expect(text.contains("== Antigravity (cli) =="))
        #expect(text.contains("Gemini 5-hour: 98% left"))
        #expect(text.contains("Resets in 34m"))
        #expect(text.contains("Gemini weekly: 96% left"))
        #expect(text.contains("Resets in 2d 15h"))
        #expect(text.contains("Claude/GPT 5-hour: 99% left"))
        #expect(text.contains("Resets in 5h"))
        #expect(text.contains("Account: quota-user@example.com"))
        #expect(text.contains("Plan: Google Ai Pro"))

        #expect(!text.contains("Gemini Models"))
        #expect(!text.contains("Claude and GPT"))
        #expect(!text.contains("Pace:"))
    }

    @Test
    func `an untouched quota family drops out of the rendered lanes`() {
        let text = Self.renderedText(Self.quotaSummarySnapshot(
            geminiSessionPercent: 2,
            geminiWeeklyPercent: 4,
            thirdPartySessionPercent: 0))

        #expect(text.contains("Gemini 5-hour: 98% left"))
        #expect(text.contains("Gemini weekly: 96% left"))
        #expect(!text.contains("Claude/GPT"))
    }

    @Test
    func `a lane with unknown usage keeps its family visible`() {
        let text = Self.renderedText(Self.quotaSummarySnapshot(
            geminiSessionPercent: 2,
            geminiWeeklyPercent: 4,
            thirdPartySessionPercent: 0,
            includeUnknownThirdPartyLane: true))

        #expect(text.contains("Claude/GPT 5-hour: 100% left"))
        #expect(text.contains("Claude/GPT weekly: Unavailable"))
        #expect(!text.contains("Claude/GPT weekly: 100% left"))
    }

    @Test
    func `every family untouched keeps all lanes visible`() {
        let text = Self.renderedText(Self.quotaSummarySnapshot(
            geminiSessionPercent: 0,
            geminiWeeklyPercent: 0,
            thirdPartySessionPercent: 0))

        #expect(text.contains("Gemini 5-hour: 100% left"))
        #expect(text.contains("Gemini weekly: 100% left"))
        #expect(text.contains("Claude/GPT 5-hour: 100% left"))
    }

    @Test
    func `legacy modelQuotas snapshot keeps the collapsed lane rendering unchanged`() {
        let text = Self.renderedText(Self.legacyModelQuotasSnapshot())

        #expect(text.contains("Gemini Models: 98% left"))
        #expect(text.contains("Claude and GPT: 96% left"))
        #expect(!text.contains("Gemini 5-hour"))
        #expect(!text.contains("Claude/GPT"))
    }

    @Test
    func `cards metric collection mirrors the quota summary lanes`() {
        let snapshot = Self.quotaSummarySnapshot(
            geminiSessionPercent: 2,
            geminiWeeklyPercent: 4,
            thirdPartySessionPercent: 1)
        let metrics = CLIRenderer.collectCardMetrics(
            provider: .antigravity,
            snapshot: snapshot,
            resetStyle: .countdown,
            now: Self.now)

        #expect(metrics.map(\.label) == ["Gemini 5-hour", "Gemini weekly", "Claude/GPT 5-hour"])
        #expect(metrics.map { $0.remainingPercent?.rounded() } == [98, 96, 99])
    }

    @Test
    func `cards metric collection drops an untouched family`() {
        let labels = Self.cardMetricLabels(Self.quotaSummarySnapshot(
            geminiSessionPercent: 2,
            geminiWeeklyPercent: 4,
            thirdPartySessionPercent: 0))

        #expect(labels == ["Gemini 5-hour", "Gemini weekly"])
    }

    @Test
    func `cards metric collection keeps legacy lanes when there is no quota summary`() {
        #expect(Self.cardMetricLabels(Self.legacyModelQuotasSnapshot()) == ["Gemini Models", "Claude and GPT"])
    }

    @Test
    func `unknown quota text and compact rows retain reset context without invented capacity`() {
        let snapshot = Self.unknownSnapshot()
        let text = Self.renderedText(snapshot)
        let compact = CLIRenderer.renderCardBodyLines(
            provider: .antigravity,
            snapshot: snapshot,
            credits: nil,
            context: Self.renderContext(),
            includeIdentity: false,
            now: Self.now).joined(separator: "\n")
        for output in [text, compact] {
            #expect(output.contains("Gemini weekly: Unavailable"))
            #expect(output.contains("Resets in 7d"))
            #expect(!output.contains("% left"))
            #expect(!output.contains("[============]"))
        }
    }

    @Test(arguments: [false, true])
    func `full cards show unknown quota without a percentage or bar`(enhanced: Bool) {
        let card = Self.card(Self.unknownSnapshot())
        #expect(card.metrics.first?.remainingPercent == nil)
        let output = TextParsing.stripANSICodes(CLICardsRenderer.render(
            cards: [card], failures: [], terminalWidth: 80, useColor: true, enhanced: enhanced))
        #expect(output.contains("Gemini weekly"))
        #expect(output.contains("Unavailable"))
        #expect(output.contains("Reset in 7d"))
        #expect(!output.contains("% left"))
        #expect(!output.contains("━"))
    }

    @Test
    func `brief cards preserve an unknown first quota ahead of a known quota`() {
        let card = Self.card(Self.unknownSnapshot(includeKnownLane: true))
        let rows = CLICardsBriefRenderer.makeRows(cards: [card])
        #expect(card.metrics.count == 2)
        #expect(rows.first?.metricLabel == "Gemini weekly")
        #expect(rows.first?.usedPercent == nil)
        #expect(rows.first?.resetAt == Self.now.addingTimeInterval(7 * 86400))
        let output = CLICardsBriefRenderer.render(
            rows: rows, failures: [], terminalWidth: 120, useColor: false, now: Self.now)
        #expect(output.contains("7d"))
        #expect(!output.contains("0%"))
    }
}
