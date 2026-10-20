import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

/// Each case moves one budget input and compares only the signature component that must notice it, since the
/// provider cost also moves unrelated components.
@MainActor
@Suite(.serialized)
struct StatusItemSpendSignatureTests {
    @Test
    func `spend percent and money tokens sign the budget`() {
        let harness = Self.makeHarness(lines: [[.icon, .percent(window: .spend), .spendBudget]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        let first = harness.component("layoutSpend", used: 420, limit: 1000)
        #expect(first?.hasPrefix("layoutSpend=used=42.000,") == true)
        #expect(first?.contains("budget=$420 / $1,000") == true)
        #expect(harness.component("layoutSpend", used: 450, limit: 1000) != first)
        #expect(harness.component("layoutSpend", used: 420, limit: 1250) != first)
    }

    @Test
    func `layouts without spend percent or money tokens do not sign the budget`() {
        let harness = Self.makeHarness(lines: [[.icon, .percent(window: .session)]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        #expect(harness.component("layoutSpend", used: 420) == "layoutSpend=nil")
    }

    @Test
    func `spend pace token moves the pace component`() {
        let harness = Self.makeHarness(lines: [[.pace(window: .spend)]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        // Twelve days from the reset, 20% used is well behind the even pace and 80% well ahead of it.
        #expect(harness.component("layoutPace", used: 200)?.hasPrefix("layoutPace=spend=-") == true)
        #expect(harness.component("layoutPace", used: 800)?.hasPrefix("layoutPace=spend=+") == true)
    }

    @Test
    func `spend reset token follows a moved period boundary through the reset component`() {
        let harness = Self.makeHarness(lines: [[.windowResetCountdown(window: .spend)]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        let early = harness.component("layoutResets", used: 420, resetsInDays: 12)
        #expect(early != "layoutResets=nil")
        #expect(harness.component("layoutResets", used: 420, resetsInDays: 20) != early)
    }

    @Test
    func `spend percent predicate moves the conditional window component alone`() {
        let harness = Self.makeHarness(metric: .spend, comparison: .greaterThan, threshold: 50)
        defer { harness.controller.releaseStatusItemsForTesting() }

        let below = harness.component("layoutCondWindows", used: 420)
        #expect(below?.hasPrefix("layoutCondWindows=spend=") == true)
        #expect(harness.component("layoutCondWindows", used: 550) != below)
        #expect(harness.component("layoutSpend", used: 420) == "layoutSpend=nil")
    }

    @Test
    func `spend reset predicate follows a moved period boundary`() {
        let harness = Self.makeHarness(metric: .spendResetsIn, comparison: .lessThan, threshold: 48)
        defer { harness.controller.releaseStatusItemsForTesting() }

        let early = harness.component("layoutCondWindows", used: 420, resetsInDays: 1)
        #expect(early?.hasPrefix("layoutCondWindows=spendResetsIn=") == true)
        #expect(harness.component("layoutCondWindows", used: 420, resetsInDays: 20) != early)
    }

    @Test
    func `spend pace predicate moves the pace component`() {
        let harness = Self.makeHarness(metric: .spendPace, comparison: .greaterThan, threshold: 5)
        defer { harness.controller.releaseStatusItemsForTesting() }

        // Twelve days from the reset, 20% used is well behind the even pace and 80% well ahead of it.
        #expect(harness.component("layoutPace", used: 200)?.hasPrefix("layoutPace=spend=-") == true)
        #expect(harness.component("layoutPace", used: 800)?.hasPrefix("layoutPace=spend=+") == true)
    }

    @Test
    func `spend amount predicate signs the unrounded USD figures`() {
        let harness = Self.makeHarness(metric: .spendAmount, comparison: .greaterThan, threshold: 420.005)
        defer { harness.controller.releaseStatusItemsForTesting() }

        // Both amounts display as "$420", so only the exact USD figure can tell them apart.
        let below = harness.component("layoutSpend", used: 420.00, limit: 100_000)
        #expect(below?.contains("usedUSD=unused") == false)
        #expect(harness.component("layoutSpend", used: 420.01, limit: 100_000) != below)
    }

    @MainActor
    private struct Harness {
        let store: UsageStore
        let controller: StatusItemController
        let now: Date

        /// The named `key=value` component of the observation signature after the budget moves.
        func component(
            _ name: String,
            used: Double,
            limit: Double = 1000,
            resetsInDays: Double = 12)
            -> String?
        {
            let budget = ProviderCostSnapshot(
                used: used,
                limit: limit,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: self.now.addingTimeInterval(resetsInDays * 24 * 60 * 60),
                updatedAt: self.now)
            self.store._setSnapshotForTesting(
                UsageSnapshot(primary: nil, secondary: nil, providerCost: budget, updatedAt: self.now),
                provider: .claude)
            return self.controller.storeIconObservationSignature()
                .split(separator: "|")
                .first { $0.hasPrefix("\(name)=") }
                .map(String.init)
        }
    }

    /// A layout whose only link to the budget is a conditional predicate: no spend token is placed.
    private static func makeHarness(
        metric: MenuBarConditionalMetric,
        comparison: MenuBarConditionalComparison,
        threshold: Double)
        -> Harness
    {
        let conditional = MenuBarLayoutConditional(
            name: "gate",
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: metric, comparison: comparison, threshold: threshold))],
            thenToken: .providerName,
            elseToken: .hidden)
        return self.makeHarness(
            lines: [[.icon, .conditional(id: conditional.id)]],
            conditionals: [conditional])
    }

    private static func makeHarness(
        lines: [[MenuBarLayoutToken]],
        conditionals: [MenuBarLayoutConditional] = [])
        -> Harness
    {
        let settings = testSettingsStore(suiteName: "StatusItemSpendSignatureTests")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarLayoutConditionals = conditionals
        settings.menuBarLayout = MenuBarLayout(lines: lines)
        if let claudeMeta = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return Harness(store: store, controller: controller, now: Date())
    }
}
