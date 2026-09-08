import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

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
            accountEmail: "peter.urda@gmail.com",
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
        #expect(text.contains("Account: peter.urda@gmail.com"))
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
        #expect(text.contains("Claude/GPT weekly"))
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
        #expect(metrics.map { $0.remainingPercent.rounded() } == [98, 96, 99])
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
}
