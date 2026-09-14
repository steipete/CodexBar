import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct WarpAutomaticCreditsTests {
    @Test(arguments: [
        (1500, 770, 1000, false, 77.0),
        (375, 0, 1000, false, 75.0),
        (1500, 1000, 1000, false, 100.0),
        (1500, 0, 1000, false, 0.0),
        (1500, 0, 0, false, 0.0),
        (375, 770, 1000, false, 75.0),
        (1500, 770, 1000, true, 100.0),
    ])
    func `automatic follows monthly then add-on credits`(
        used: Int, bonus: Int, bonusTotal: Int, unlimited: Bool, remaining: Double) throws
    {
        let snapshot = WarpUsageSnapshot(
            requestLimit: 1500,
            requestsUsed: used,
            nextRefreshTime: nil,
            isUnlimited: unlimited,
            updatedAt: .now,
            bonusCreditsRemaining: bonus,
            bonusCreditsTotal: bonusTotal).toUsageSnapshot()
        let automatic = try #require(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .warp, snapshot: snapshot, supportsAverage: false))
        #expect(abs(automatic.remainingPercent - remaining) < 0.001)
        for (preference, expected): (MenuBarMetricPreference, RateWindow?) in [
            (.primary, snapshot.primary), (.secondary, snapshot.secondary ?? snapshot.primary),
        ] {
            let selected = MenuBarMetricWindowResolver.rateWindow(
                preference: preference, provider: .warp, snapshot: snapshot, supportsAverage: false)
            #expect(selected?.usedPercent == expected?.usedPercent)
        }
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: .warp, snapshot: snapshot)
        #expect(semantic.session == snapshot.primary)
        #expect(semantic.weekly == snapshot.secondary)
        let data = MenuBarLayoutRenderData(
            provider: .warp,
            iconKey: "warp",
            providerName: "Warp",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .warp, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(snapshot.primary),
            secondary: MenuBarLayoutRenderWindow(snapshot.secondary),
            tertiary: nil,
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
        for showUsed in [false, true] {
            let expectedSwitcher = showUsed ? 100 - remaining : remaining
            let switcher = try #require(StatusItemController.switcherWeeklyMetricPercent(
                for: .warp, snapshot: snapshot, showUsed: showUsed))
            #expect(abs(switcher - expectedSwitcher) < 0.001)
            for preference in [MenuBarMetricPreference.primary, .secondary] {
                let explicitSwitcher = StatusItemController.switcherWeeklyMetricPercent(
                    for: .warp, snapshot: snapshot, showUsed: showUsed, preference: preference)
                #expect(explicitSwitcher ==
                    (showUsed ? snapshot.primary?.usedPercent : snapshot.primary?.remainingPercent))
            }
            let output = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: showUsed,
                    conditionals: [],
                    appearanceName: NSAppearance.Name.aqua.rawValue,
                    isDebugApp: false,
                    now: .now))
            if used == 1500, bonus == 770, !unlimited,
               let directory = ProcessInfo.processInfo.environment["CODEXBAR_WARP_PROOF_DIR"]
            {
                let file = URL(fileURLWithPath: directory)
                    .appendingPathComponent(showUsed ? "used.txt" : "remaining.txt")
                try output.attributedTitle.string.write(to: file, atomically: true, encoding: .utf8)
            }
            #expect(output.attributedTitle.string == "\(Int(showUsed ? 100 - remaining : remaining))%")
            if used == 1500, bonus == 770, !unlimited {
                for (window, expected): (PercentWindow, String) in [
                    (.session, showUsed ? "C 100%" : "C 0%"),
                    (.weekly, showUsed ? "A 23%" : "A 77%"),
                ] {
                    let explicit = MenuBarLayoutRenderer().render(
                        layout: MenuBarLayout(lines: [[.percent(window: window)]]),
                        data: data,
                        icon: nil,
                        options: MenuBarLayoutRenderOptions(
                            size: .regular,
                            highContrast: false,
                            showUsed: showUsed,
                            conditionals: [],
                            appearanceName: NSAppearance.Name.aqua.rawValue,
                            isDebugApp: false,
                            now: .now))
                    #expect(explicit.attributedTitle.string == expected)
                }
            }
        }
    }

    @Test
    func `missing monthly window still exposes add-ons`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 23, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: .now)
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .warp,
            snapshot: snapshot,
            supportsAverage: false)?.remainingPercent == 77)
    }
}
