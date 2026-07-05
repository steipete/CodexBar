import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarResetTimeDisplayTests {
    @Test
    func `reset time mode formats the selected window reset`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(2 * 3600)
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: resetsAt,
            resetDescription: nil)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true,
            resetTimeDisplayStyle: .absolute,
            now: now)

        #expect(text == "↻ \(UsageFormatter.resetDescription(from: resetsAt, now: now))")
    }

    @Test
    func `reset time mode uses countdown preference`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(2 * 3600 + 15 * 60)
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: resetsAt,
            resetDescription: nil)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true,
            resetTimeDisplayStyle: .countdown,
            now: now)

        #expect(text == "↻ in 2h 15m")
    }

    @Test
    func `reset time mode falls back to used percent without reset metadata`() {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true)

        #expect(text == "42%")
    }

    @Test
    func `reset time mode uses text reset metadata`() {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: "in 2h 15m")

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true)

        #expect(text == "↻ in 2h 15m")
    }

    @Test(arguments: [
        "Resets in 2h",
        "tomorrow, 3:00 PM",
        "next week",
        "expires in 4d",
    ])
    func `reset time mode accepts reset timing phrases`(_ description: String) {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: description)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true)

        #expect(text == "↻ \(description)")
    }

    @Test(arguments: [
        "250/1000 requests",
        "160 requests",
        "5 hours window",
        "$10.00 available",
    ])
    func `reset time mode rejects non-reset provider summaries`(_ description: String) {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: description)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true)

        #expect(text == "42%")
    }

    @Test
    func `reset time mode falls back to remaining percent without reset metadata`() {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: false)

        #expect(text == "58%")
    }
}

@Suite(.serialized)
@MainActor
struct MenuBarMiniMaxResetTimeDisplayTests {
    @Test
    func `reset time mode shows nearest minimax quota reset`() {
        let settings = testSettingsStore(suiteName: "MenuBarMiniMaxResetTimeDisplayTests-nearest-reset")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .minimax
        settings.menuBarDisplayMode = .resetTime
        settings.resetTimesShowAbsolute = true
        settings.setMenuBarMetricPreference(.automatic, for: .minimax)
        if let metadata = ProviderRegistry.shared.metadata[.minimax] {
            settings.setProviderEnabled(provider: .minimax, metadata: metadata, enabled: true)
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let sessionReset = now.addingTimeInterval(3 * 3600)
        let weeklyReset = now.addingTimeInterval(3 * 24 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 3,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: now)

        let resetWindow = controller.menuBarResetTimeWindow(for: .minimax, snapshot: snapshot)
        #expect(resetWindow?.resetsAt == sessionReset)

        let displayText = controller.menuBarDisplayText(for: .minimax, snapshot: snapshot)

        #expect(displayText == "↻ \(UsageFormatter.resetDescription(from: sessionReset, now: now))")
    }

    @Test
    func `reset time mode honors explicit weekly metric preference`() {
        let settings = testSettingsStore(suiteName: "MenuBarMiniMaxResetTimeDisplayTests-explicit-weekly")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .minimax
        settings.menuBarDisplayMode = .resetTime
        settings.resetTimesShowAbsolute = true
        settings.setMenuBarMetricPreference(.secondary, for: .minimax)
        if let metadata = ProviderRegistry.shared.metadata[.minimax] {
            settings.setProviderEnabled(provider: .minimax, metadata: metadata, enabled: true)
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let sessionReset = now.addingTimeInterval(3 * 3600)
        let weeklyReset = now.addingTimeInterval(3 * 24 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 3,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: now)

        let resetWindow = controller.menuBarResetTimeWindow(for: .minimax, snapshot: snapshot)
        #expect(resetWindow?.resetsAt == weeklyReset)
    }
}
