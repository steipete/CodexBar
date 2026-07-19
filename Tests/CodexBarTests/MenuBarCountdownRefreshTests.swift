import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarCountdownRefreshTests {
    @Test
    func `countdown refresh delay follows the next displayed minute boundary`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let delay = StatusItemController.menuBarCountdownRefreshDelay(
            resetDates: [
                now.addingTimeInterval(2 * 3600 + 15 * 60 + 30),
                now.addingTimeInterval(45),
            ],
            now: now)

        #expect(abs((delay ?? 0) - 30.05) < 0.001)
    }

    @Test
    func `countdown refresh ignores elapsed reset dates`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let delay = StatusItemController.menuBarCountdownRefreshDelay(
            resetDates: [now.addingTimeInterval(-1)],
            now: now)

        #expect(delay == nil)
    }

    @Test
    func `absolute refresh observes local midnight before the reset`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 23,
            minute: 59)))
        let reset = try #require(calendar.date(byAdding: .hour, value: 2, to: now))

        let delay = StatusItemController.menuBarAbsoluteRefreshDelay(
            resetDates: [reset],
            now: now,
            calendar: calendar)

        #expect(abs((delay ?? 0) - 60.05) < 0.001)
    }

    @Test
    func `absolute refresh observes midnight after a skipped day start`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2024,
            month: 9,
            day: 8,
            hour: 23)))
        let reset = try #require(calendar.date(byAdding: .hour, value: 3, to: now))

        let delay = StatusItemController.menuBarAbsoluteRefreshDelay(
            resetDates: [reset],
            now: now,
            calendar: calendar)

        #expect(abs((delay ?? 0) - 3600.05) < 0.001)
    }

    @Test
    func `status item schedules countdown and exhausted lane refreshes`() {
        let settings = testSettingsStore(suiteName: "MenuBarCountdownRefreshTests-scheduling")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .resetTime
        settings.resetTimesShowAbsolute = false
        if let metadata = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 42,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(90),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        settings.resetTimesShowAbsolute = true
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        settings.menuBarShowsBrandIconWithPercent = false
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
        settings.menuBarShowsBrandIconWithPercent = true

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(90),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(-1),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        controller.updateIcons()
        // The elapsed weekly cap falls out of the projection; absolute reset-time mode now observes the
        // still-future session reset instead of leaving its label stale.
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(90),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        settings.resetTimesShowAbsolute = false
        store._setSnapshotForTesting(nil, provider: .codex)
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 42,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(90),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        controller.prepareForAppShutdown()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
    }

    @Test
    func `custom countdown schedules independently of legacy reset settings`() throws {
        try self.expectCustomResetTokenSchedules(
            .resetCountdown,
            legacyAbsoluteReset: true,
            suiteName: "MenuBarCountdownRefreshTests-custom-countdown")
    }

    @Test
    func `custom absolute reset schedules independently of legacy reset settings`() throws {
        try self.expectCustomResetTokenSchedules(
            .resetAbsolute,
            legacyAbsoluteReset: false,
            suiteName: "MenuBarCountdownRefreshTests-custom-absolute")
    }

    @Test
    func `absolute clock smart mode schedules the exhausted reset boundary`() {
        // Isolated defaults: this test enables the smart option, which must not leak into `.standard`
        // and flip other suites' exhausted-lane expectations.
        let settings = testSettingsStore(suiteName: "MenuBarCountdownRefreshTests-absolute-smart")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .percent
        settings.menuBarShowsResetTimeWhenExhausted = true
        // Absolute clock style: the per-minute countdown scheduler is skipped, but a smart-exhausted
        // lane still needs a boundary refresh so it falls back to the percentage once the reset passes.
        settings.resetTimesShowAbsolute = true
        if let metadata = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()

        // Exhausted lane with a future reset → schedule a boundary refresh even in absolute mode.
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(90),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller._test_isMenuBarCountdownRefreshScheduled())

        // Elapsed reset → nothing to schedule (the lane already falls back to the percentage).
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(-1),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())

        // Healthy quota → smart replacement inactive, so no boundary refresh.
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(90),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
    }

    @Test(arguments: [MenuBarDisplayMode.percent, .pace, .both])
    func `combined metric schedules every displayed exhausted reset lane`(mode: MenuBarDisplayMode) {
        for usesAbsoluteClock in [false, true] {
            // Isolated defaults: enabling the smart option must not leak into `.standard`.
            let settings = testSettingsStore(
                suiteName: "MenuBarCountdownRefreshTests-combined-lanes-\(mode.rawValue)-\(usesAbsoluteClock)")
            settings.statusChecksEnabled = false
            settings.refreshFrequency = .manual
            settings.menuBarShowsBrandIconWithPercent = true
            settings.menuBarDisplayMode = mode
            settings.menuBarShowsResetTimeWhenExhausted = true
            settings.resetTimesShowAbsolute = usesAbsoluteClock
            settings.mergeIcons = false
            settings.selectedMenuProvider = .claude
            settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)
            if let metadata = ProviderRegistry.shared.metadata[.claude] {
                settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
            }

            let fetcher = UsageFetcher()
            let store = UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
            let now = Date()
            // Both combined lanes exhausted: the session (5h) reset has already elapsed, the weekly (7d)
            // reset is still ahead. The scheduler must consider the weekly lane, not just the icon-metric
            // lane, so the still-displayed weekly countdown or absolute clock reaches its reset boundary.
            let sessionReset = now.addingTimeInterval(-60)
            let weeklyReset = now.addingTimeInterval(3600)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 100,
                        windowMinutes: 300,
                        resetsAt: sessionReset,
                        resetDescription: nil),
                    secondary: RateWindow(
                        usedPercent: 100,
                        windowMinutes: 10080,
                        resetsAt: weeklyReset,
                        resetDescription: nil),
                    updatedAt: now),
                provider: .claude)

            let controller = StatusItemController(
                store: store,
                settings: settings,
                account: fetcher.loadAccountInfo(),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: .system)
            controller.updateIcons()

            let dates = controller.menuBarDisplayedResetDates(for: .claude, now: now)
            switch mode {
            case .percent:
                // Percent displays both lane values independently.
                #expect(dates == [sessionReset, weeklyReset])
            case .pace, .both:
                // Pace/both surface the exhausted weekly lane, not the session lane that wins the 100/100
                // icon-metric tie.
                #expect(dates == [weeklyReset])
            case .resetTime:
                Issue.record("reset-time mode is not an argument for this smart-reset test")
            }
            // The future weekly boundary stays scheduled for countdown and absolute-clock styles even
            // though the session lane elapsed.
            #expect(controller._test_isMenuBarCountdownRefreshScheduled())
            controller.releaseStatusItemsForTesting()
        }
    }

    @Test
    func `combined metric falls through to a nonstandard exhausted fallback lane`() {
        let settings = testSettingsStore(suiteName: "MenuBarCountdownRefreshTests-combined-fallback")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .percent
        settings.menuBarShowsResetTimeWhenExhausted = true
        settings.resetTimesShowAbsolute = false
        settings.mergeIcons = false
        settings.selectedMenuProvider = .claude
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)
        if let metadata = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 60,
                resetsAt: reset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.menuBarDisplayText(for: .claude, snapshot: snapshot, now: now) == "↻ in 1h")
        #expect(controller.menuBarDisplayedResetDates(for: .claude, now: now) == [reset])
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }

    @Test
    func `time environment change reschedules an absolute reset label`() {
        let settings = testSettingsStore(suiteName: "MenuBarCountdownRefreshTests-time-environment")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .resetTime
        settings.resetTimesShowAbsolute = true
        if let metadata = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 42,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)

        controller.handleMenuBarTimeEnvironmentChange()

        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }

    @Test
    func `merged highest usage observes reset for noncurrent Codex candidate`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarCountdownRefreshTests-merged-highest")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsHighestUsage = true
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .percent
        settings.resetTimesShowAbsolute = true

        let registry = ProviderRegistry.shared
        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(registry.metadata[.codex]),
            enabled: true)
        try settings.setProviderEnabled(
            provider: .claude,
            metadata: #require(registry.metadata[.claude]),
            enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(90),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        controller.updateIcons()
        #expect(controller.primaryProviderForUnifiedIcon() == .claude)
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }

    private func expectCustomResetTokenSchedules(
        _ layoutElement: MenuBarLayoutToken,
        legacyAbsoluteReset: Bool,
        suiteName: String) throws
    {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.selectedMenuProvider = .claude
        settings.menuBarIconStyle = .iconAndPercent
        settings.menuBarDisplayMode = .percent
        settings.menuBarShowsResetTimeWhenExhausted = false
        settings.resetTimesShowAbsolute = legacyAbsoluteReset
        settings.setMenuBarLayout(MenuBarLayout(lines: [[.icon, layoutElement]]), for: .claude)

        let registry = ProviderRegistry.shared
        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(registry.metadata[.codex]),
            enabled: false)
        try settings.setProviderEnabled(
            provider: .claude,
            metadata: #require(registry.metadata[.claude]),
            enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        let reset = now.addingTimeInterval(90)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 42,
                    windowMinutes: 300,
                    resetsAt: reset,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.menuBarDisplayedResetDates(for: .claude, now: now) == [reset])
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }
}
