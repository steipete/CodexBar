import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

/// A conditional predicate can depend on data no display token exposes. When the observation signature
/// misses that dependency the observer skips `updateIcons()` and the menu bar keeps rendering the branch
/// that was true before the data moved, so each case here pins one such dependency.
@MainActor
@Suite(.serialized)
struct StatusItemConditionalSignatureTests {
    @Test
    func `over-quota used-direction lane predicate moves the signature`() {
        let harness = Self.makeHarness(
            suite: "StatusItemConditionalSignatureTests-lane-over-quota",
            metric: .primaryLane,
            direction: .used,
            comparison: .greaterThan,
            threshold: 105)
        // Rendered lanes show remaining, which clamps at zero: both snapshots display 0% remaining.
        harness.settings.usageBarsShowUsed = false

        let below = harness.signature(primaryUsedPercent: 104)
        let above = harness.signature(primaryUsedPercent: 106)

        #expect(below.contains("layoutCondWindows=primaryLane="))
        #expect(below != above)
    }

    @Test
    func `countdown predicate follows a moved reset timestamp`() {
        let harness = Self.makeHarness(
            suite: "StatusItemConditionalSignatureTests-reset-moved",
            metric: .sessionResetsIn,
            direction: .used,
            comparison: .lessThan,
            threshold: 2)

        // Identical usage, different reset instant: only the countdown predicate can tell them apart.
        let near = harness.signature(primaryUsedPercent: 30, sessionResetInHours: 1)
        let far = harness.signature(primaryUsedPercent: 30, sessionResetInHours: 5)

        #expect(near.contains("layoutCondWindows=sessionResetsIn="))
        #expect(near != far)
    }

    @Test
    func `cost predicate signs the unrounded amount`() {
        let harness = Self.makeHarness(
            suite: "StatusItemConditionalSignatureTests-cost-subcent",
            metric: .costToday,
            direction: .used,
            comparison: .greaterThan,
            threshold: 1.2345)

        // Both amounts format to "$1.23", so only the numeric component can separate them.
        let below = harness.signature(primaryUsedPercent: 30, todayCostUSD: 1.2344)
        let above = harness.signature(primaryUsedPercent: 30, todayCostUSD: 1.2346)

        #expect(below.contains("todayUSD="))
        #expect(below != above)
    }

    /// Thresholds are USD. `UsageFormatter.convertedCost` returns the source amount unchanged when it has
    /// no rate for the provider's currency, so handing that value over would compare a foreign amount
    /// against a USD threshold. The display string must still render in the provider's own currency.
    @Test
    func `cost in an unconvertible currency yields no USD metric`() {
        let harness = Self.makeHarness(
            suite: "StatusItemConditionalSignatureTests-cost-currency",
            metric: .costToday,
            direction: .used,
            comparison: .greaterThan,
            threshold: 5)

        _ = harness.signature(primaryUsedPercent: 30, todayCostUSD: 6, currencyCode: "XXX")
        let unconvertible = harness.controller.menuBarLayoutCosts(provider: .claude)
        #expect(unconvertible.todayUSD == nil)
        #expect(unconvertible.last30DaysUSD == nil)
        // The rendered text is unaffected: it stays in the provider's reported currency.
        #expect(unconvertible.today != nil)

        _ = harness.signature(primaryUsedPercent: 30, todayCostUSD: 6, currencyCode: "USD")
        let usd = harness.controller.menuBarLayoutCosts(provider: .claude)
        #expect(usd.todayUSD == 6)
    }

    @MainActor
    private struct Harness {
        let settings: SettingsStore
        let store: UsageStore
        let controller: StatusItemController
        let now: Date

        func signature(
            primaryUsedPercent: Double,
            sessionResetInHours: Double = 1,
            todayCostUSD: Double? = nil,
            currencyCode: String = "USD")
            -> String
        {
            self.store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: primaryUsedPercent,
                        windowMinutes: 300,
                        resetsAt: self.now.addingTimeInterval(sessionResetInHours * 60 * 60),
                        resetDescription: nil),
                    secondary: RateWindow(
                        usedPercent: 60,
                        windowMinutes: 10080,
                        resetsAt: self.now.addingTimeInterval(3 * 24 * 60 * 60),
                        resetDescription: nil),
                    updatedAt: self.now),
                provider: .claude)
            if let todayCostUSD {
                self.store._setTokenSnapshotForTesting(
                    Self.tokenSnapshot(
                        todayCostUSD: todayCostUSD,
                        currencyCode: currencyCode,
                        now: self.now),
                    provider: .claude)
            }
            return self.controller.storeIconObservationSignature()
        }

        private static func tokenSnapshot(
            todayCostUSD: Double,
            currencyCode: String,
            now: Date)
            -> CostUsageTokenSnapshot
        {
            let formatter = DateFormatter()
            formatter.calendar = .current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: todayCostUSD,
                currencyCode: currencyCode,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: formatter.string(from: now),
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: nil,
                        costUSD: todayCostUSD,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now)
        }
    }

    private static func makeHarness(
        suite: String,
        metric: MenuBarConditionalMetric,
        direction: MenuBarConditionalDirection,
        comparison: MenuBarConditionalComparison,
        threshold: Double)
        -> Harness
    {
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true

        let conditional = MenuBarLayoutConditional(
            name: "gate",
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(
                    metric: metric,
                    direction: direction,
                    comparison: comparison,
                    threshold: threshold))],
            thenToken: .resetCountdown,
            elseToken: .hidden)
        settings.menuBarLayoutConditionals = [conditional]
        settings.menuBarLayout = MenuBarLayout(lines: [[.icon, .conditional(id: conditional.id)]])

        if let claudeMeta = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return Harness(settings: settings, store: store, controller: controller, now: Date())
    }
}
