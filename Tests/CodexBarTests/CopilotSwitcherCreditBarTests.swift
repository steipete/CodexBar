import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CopilotSwitcherCreditBarTests {
    func makeSnapshot(
        used: Double,
        total: Double? = 3800,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        rowID: String = CopilotCreditDetailRows.seatRowID) throws -> UsageSnapshot
    {
        let progress = try total.map { try ProviderDetailSection.Row.Progress(used: used, total: $0) }
        let row = try ProviderDetailSection.Row(
            id: rowID,
            label: "Credits used",
            value: "Credits",
            progress: progress,
            usageValue: used)
        return try UsageSnapshot(
            primary: primary,
            secondary: secondary,
            details: [ProviderDetailSection(title: "Credits", rows: [row])],
            updatedAt: Date())
    }

    @Test(arguments: [0.0, 1351.0, 3800.0, 4000.0])
    func `copilot switcher uses seat credits in both display modes`(used: Double) throws {
        let snapshot = try self.makeSnapshot(used: used)
        let usedPercent = used / 3800 * 100

        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: snapshot,
            showUsed: true) == usedPercent)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: snapshot,
            showUsed: false) == max(0, 100 - usedPercent))
    }

    @Test
    func `copilot switcher preserves metered quota before seat credits`() throws {
        let primary = RateWindow(usedPercent: 28, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = try self.makeSnapshot(used: 1351, primary: primary)

        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: snapshot,
            showUsed: false) == 72)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: snapshot,
            showUsed: true) == 28)
    }

    @Test
    func `copilot switcher hides bar without a credit entitlement`() throws {
        let snapshot = try self.makeSnapshot(used: 1351, total: nil)

        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: snapshot,
            showUsed: false) == nil)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: nil,
            showUsed: true) == nil)
    }

    @Test
    func `switcher credit fallback only reads copilot seat credits`() throws {
        let snapshot = try self.makeSnapshot(used: 1351)
        let unrelatedRow = try self.makeSnapshot(used: 1351, rowID: "other-credits")

        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .claude,
            snapshot: snapshot,
            showUsed: false) == nil)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: unrelatedRow,
            showUsed: false) == nil)
    }

    @Test(arguments: MenuBarMetricPreference.allCases.filter { $0 != .automatic })
    func `explicit missing metrics do not substitute seat credits`(_ preference: MenuBarMetricPreference) throws {
        let snapshot = try self.makeSnapshot(used: 1351)
        for showUsed in [false, true] {
            #expect(StatusItemController.switcherWeeklyMetricPercent(
                for: .copilot,
                snapshot: snapshot,
                showUsed: showUsed,
                preference: preference) == nil)
        }
    }

    @Test(arguments: [0.0, 28.0])
    func `real primary keeps priority over secondary and credits`(_ primaryUsage: Double) throws {
        let primary = RateWindow(usedPercent: primaryUsage, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 76, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = try self.makeSnapshot(used: 1351, primary: primary, secondary: secondary)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: snapshot,
            showUsed: true) == primaryUsage)
    }

    @Test
    func `weekly quota retains priority over primary and credits`() throws {
        let primary = RateWindow(usedPercent: 28, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let weekly = RateWindow(usedPercent: 76, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let snapshot = try self.makeSnapshot(used: 1351, primary: primary, secondary: weekly)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .copilot,
            snapshot: snapshot,
            showUsed: true) == 76)
    }

    @MainActor
    @Test
    func `clearing and restoring the allowance updates the retained native switcher`() throws {
        var snapshot = try self.makeSnapshot(used: 1351)
        let view = ProviderSwitcherView(
            providers: [.copilot],
            selected: .provider(.copilot),
            includesOverview: false,
            width: 190,
            showsIcons: false,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { provider in
                StatusItemController.switcherWeeklyMetricPercent(for: provider, snapshot: snapshot, showUsed: true)
            },
            onSelect: { _ in })
        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        #expect(view._test_quotaIndicatorFillRatios().count == 1)
        #expect(try #require(view._test_quotaIndicatorFillFrames().first).width > 0)

        snapshot = try #require(snapshot
            .updatingCopilotSeatCreditEntitlement(CopilotCreditEntitlementParser.parse("0")))
        view.updateQuotaIndicators()
        #expect(view._test_quotaIndicatorFillRatios().isEmpty)

        snapshot = try #require(snapshot.updatingCopilotSeatCreditEntitlement(5404))
        view.updateQuotaIndicators()
        view.layoutSubtreeIfNeeded()
        #expect(view._test_quotaIndicatorFillRatios() == [0.25])
    }
}
