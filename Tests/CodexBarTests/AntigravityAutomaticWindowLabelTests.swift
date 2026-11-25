import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AntigravityAutomaticWindowLabelTests {
    @Test(arguments: [
        ([0.1, 0.8, 0.7, 0.6], "5h 10%"),
        ([0.9, 0.2, 0.7, 0.6], "W 20%"),
        ([0.9, 0.8, 0.1, 0.6], "5h 10%"),
        ([0.9, 0.8, 0.7, 0.2], "W 20%"),
    ])
    func `automatic window keeps its label beside the matching family allowances`(
        remaining: [Double],
        expected: String) throws
    {
        let json = antigravityQuotaSummaryJSON(
            geminiSession: remaining[0],
            geminiWeekly: remaining[1],
            claudeSession: remaining[2],
            claudeWeekly: remaining[3])
        let snapshot = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8)).toUsageSnapshot()
        let provider = UsageProvider.antigravity
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: provider, snapshot: snapshot)
        let automatic = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: provider, snapshot: snapshot, supportsAverage: false)
        let data = MenuBarLayoutRenderData(
            provider: provider.instanceID,
            iconKey: provider.rawValue,
            providerName: "Antigravity",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: provider, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(snapshot.primary),
            secondary: MenuBarLayoutRenderWindow(snapshot.secondary),
            tertiary: MenuBarLayoutRenderWindow(snapshot.tertiary),
            extraRateWindows: MenuBarLayoutNamedExtra.windows(provider: provider, snapshot: snapshot)
                .map(MenuBarLayoutRenderExtra.init),
            session: MenuBarLayoutRenderWindow(semantic.session),
            weekly: MenuBarLayoutRenderWindow(semantic.weekly),
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: MenuBarLayoutRenderWindow(automatic),
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: data,
            icon: nil,
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: false,
                conditionals: [],
                appearanceName: NSAppearance.Name.aqua.rawValue,
                isDebugApp: false,
                now: Date()))
        #expect(output.attributedTitle.string == expected)
    }
}
