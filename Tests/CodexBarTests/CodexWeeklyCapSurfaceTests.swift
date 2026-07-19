import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CodexWeeklyCapSurfaceTests {
    @Test
    func `menu card session metric shows weekly cap and reset`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-2 * 60 * 60))
        let projection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let session = try #require(model.metrics.first { $0.id == "primary" })
        let weekly = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(session.percent == 0)
        #expect(session.resetText == weekly.resetText)
        #expect(session.resetText != nil)
    }

    @Test
    func `primary menu bar metric and credits follow binding weekly reset`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "CodexWeeklyCapSurfaceTests-menu-bar"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.setMenuBarMetricPreference(.primary, for: .codex)

        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(3600)
        let sessionReset = now.addingTimeInterval(1800)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-7200))
        store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: now)

        let capped = controller.menuBarMetricWindow(for: .codex, snapshot: snapshot, now: now)
        let reset = controller.menuBarMetricWindow(for: .codex, snapshot: snapshot, now: weeklyReset)
        let cappedCredits = controller.menuBarCreditsRemainingForIcon(
            provider: .codex,
            snapshot: snapshot,
            now: now)
        let resetCredits = controller.menuBarCreditsRemainingForIcon(
            provider: .codex,
            snapshot: snapshot,
            now: weeklyReset)

        #expect(capped?.remainingPercent == 0)
        #expect(capped?.resetsAt == weeklyReset)
        #expect(reset?.remainingPercent == 99)
        #expect(reset?.resetsAt == sessionReset)
        #expect(cappedCredits == 80)
        #expect(resetCredits == nil)
    }

    @Test
    func `combined menu bar modes ignore exhausted weekly lane after its reset`() throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "CodexWeeklyCapSurfaceTests-combined-reset"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.usageBarsShowUsed = false
        settings.resetTimesShowAbsolute = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)

        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionReset = now.addingTimeInterval(3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 10080,
                resetsAt: now,
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-7200))
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let selected = try #require(controller.menuBarMetricWindow(for: .codex, snapshot: snapshot, now: now))
        #expect(selected.remainingPercent == 99)
        #expect(selected.resetsAt == sessionReset)

        settings.menuBarDisplayMode = .percent
        #expect(controller.menuBarDisplayText(for: .codex, snapshot: snapshot, now: now) == "5h 99%")
        settings.menuBarDisplayMode = .pace
        #expect(controller.menuBarDisplayText(for: .codex, snapshot: snapshot, now: now) == "99%")
        settings.menuBarDisplayMode = .both
        #expect(controller.menuBarDisplayText(for: .codex, snapshot: snapshot, now: now) == "99%")
        settings.menuBarDisplayMode = .resetTime
        #expect(controller.menuBarDisplayText(for: .codex, snapshot: snapshot, now: now) == "↻ in 1h")

        settings.setMenuBarMetricPreference(.primary, for: .codex)
        settings.menuBarDisplayMode = .percent
        let expiredSessionSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: now,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-7200))
        store._setSnapshotForTesting(expiredSessionSnapshot, provider: .codex)
        store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: now)

        let resetPrimary = try #require(controller.menuBarMetricWindow(
            for: .codex,
            snapshot: expiredSessionSnapshot,
            now: now))
        let resetIcon = IconRemainingResolver.resolvedRemaining(
            snapshot: expiredSessionSnapshot,
            style: .codex,
            now: now)
        #expect(resetPrimary.remainingPercent == 60)
        #expect(controller.menuBarDisplayText(for: .codex, snapshot: expiredSessionSnapshot, now: now) == "60%")
        #expect(resetIcon.primary == 60)
        #expect(resetIcon.secondary == nil)
        #expect(store.codexConsumerProjection(surface: .menuBar, now: now).menuBarFallback == .none)
    }
}
