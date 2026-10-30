import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CopilotMenuBarPaceTests {
    @Test
    func `monthly copilot quota paces the automatic menu bar token against the calendar month`() throws {
        let store = Self.store()
        let now = try Self.date("2026-07-16T12:00:00Z")
        let reset = try Self.date("2026-08-01T00:00:00Z")
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: reset, resetDescription: nil),
            secondary: nil,
            updatedAt: now)

        let data = store.menuBarLayoutRenderData(
            provider: .copilot,
            snapshot: snapshot,
            iconKey: "copilot",
            accountLabel: nil,
            costs: MenuBarLayoutCostValues(today: nil, last30Days: nil, todayUSD: nil, last30DaysUSD: nil),
            now: now)

        // July has 31 days, so noon on the 16th is half the cycle: 70% used runs 20 points ahead, matching the
        // menu card's "20% in deficit" for the same quota.
        #expect(data.automaticPace == "+20%")
        #expect(data.metrics.automaticPaceDelta == 20)
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.pace(window: .automatic)]]),
            data: data,
            icon: nil,
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: true,
                conditionals: [],
                appearanceName: "aqua",
                isDebugApp: false,
                now: now,
                colorPace: false))
        #expect(output.attributedTitle.string.hasSuffix("+20%"))
    }

    @Test
    func `monthly copilot chat quota resolves its calendar month for pace and elapsed eligibility`() throws {
        let store = Self.store()
        let now = try Self.date("2026-07-16T12:00:00Z")
        let reset = try Self.date("2026-08-01T00:00:00Z")
        let chat = RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: reset, resetDescription: nil)

        #expect(store.menuBarLayoutPaceDelta(
            provider: .copilot, window: chat, dataConfidence: .unknown, now: now) == -20)
        #expect(store.paceWindowForElapsedEligibility(provider: .copilot, window: chat).windowMinutes == 31 * 24 * 60)
    }

    @Test
    func `reset dated window without a duration still has no pace when the provider infers no month`() throws {
        let store = Self.store()
        let now = try Self.date("2026-07-16T12:00:00Z")
        let reset = try Self.date("2026-08-01T00:00:00Z")
        let window = RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: reset, resetDescription: nil)

        #expect(store.menuBarLayoutPaceText(
            provider: .factory, window: window, dataConfidence: .unknown, now: now) == nil)
        #expect(store.menuBarLayoutPaceDelta(
            provider: .factory, window: window, dataConfidence: .unknown, now: now) == nil)
        #expect(store.paceWindowForElapsedEligibility(provider: .factory, window: window).windowMinutes == nil)
    }

    private static func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "copilot-menu-bar-pace",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        return UsageStore(fetcher: UsageFetcher(), browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
    }

    private static func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
