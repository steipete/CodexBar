import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

private final class RefreshShortcutRecorder: StatusItemMenuPersistentActionDelegate {
    var refreshCount = 0
    var refreshMenuIDs: [ObjectIdentifier] = []
    var settingsCount = 0
    var quitCount = 0
    var navigationDirections: [StatusItemMenuProviderNavigationDirection] = []

    func performPersistentRefreshAction(in menuID: ObjectIdentifier) {
        self.refreshCount += 1
        self.refreshMenuIDs.append(menuID)
    }

    func performPersistentSettingsAction() {
        self.settingsCount += 1
    }

    func performPersistentQuitAction() {
        self.quitCount += 1
    }

    func performProviderNavigation(_ direction: StatusItemMenuProviderNavigationDirection) {
        self.navigationDirections.append(direction)
    }
}

@MainActor
private final class UpdateReadyUpdater: UpdaterProviding {
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    let isAvailable = true
    let unavailableReason: String? = nil
    let updateStatus = UpdateStatus(isUpdateReady: true)

    func checkForUpdates(_: Any?) {}
    func installUpdate() {}
}

@MainActor
private final class ManualRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if self.isOpen {
            self.isOpen = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        if let continuation = self.continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            self.isOpen = true
        }
    }
}

@MainActor
@Suite(.serialized)
struct StatusMenuPersistentRefreshTests {
    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuPersistentRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeController(
        settings: SettingsStore,
        updater: UpdaterProviding = DisabledUpdaterController(),
        account: AccountInfo? = nil) -> StatusItemController
    {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        if let account {
            store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
                account: account,
                configRevision: settings.configRevision,
                expiresAt: .distantFuture)
        }
        return StatusItemController(
            store: store,
            settings: settings,
            account: account ?? fetcher.loadAccountInfo(),
            updater: updater,
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func enableOnly(_ providers: Set<UsageProvider>, settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
    }

    private static func makeTokenSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 456,
            last30DaysCostUSD: 1.23,
            daily: [],
            updatedAt: Date())
    }

    @Test
    func `refresh row is custom and appears above settings`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        let settingsItem = try #require(menu.items.first { $0.title == "Settings..." })
        let refreshIndex = try #require(menu.items.firstIndex(where: { $0 === refreshItem }))
        let settingsIndex = try #require(menu.items.firstIndex(where: { $0 === settingsItem }))

        #expect(refreshItem.action == nil)
        #expect(refreshItem.target == nil)
        let refreshView = try #require(refreshItem.view)
        #expect(refreshView is any MenuCardHighlighting)
        #expect(refreshView.fittingSize.height > 0)
        #expect(controller.isPersistentRefreshItem(refreshItem))
        #expect(refreshItem.keyEquivalent.isEmpty)
        #expect(refreshItem.keyEquivalentModifierMask.isEmpty)
        #expect(refreshIndex < settingsIndex)
    }

    @Test
    func `persistent refresh installs tracking monitor and handles command R without native shortcut`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        #expect(controller.isPersistentRefreshItem(refreshItem))
        #expect(controller.providerSwitcherShortcutEventMonitor != nil)
        #expect(controller.providerSwitcherShortcutMenuID == ObjectIdentifier(menu))
        #expect(refreshItem.keyEquivalent.isEmpty)

        let gate = ManualRefreshGate()
        controller._test_manualRefreshOperation = { await gate.wait() }
        #expect(try controller.handleMenuTrackingShortcutEvent(self.keyEvent("r", keyCode: 15), menu: menu))
        for _ in 0..<20 where controller.manualRefreshTask == nil {
            await Task.yield()
        }

        let task = try #require(controller.manualRefreshTask)
        #expect(!refreshItem.isEnabled)

        gate.resume()
        await task.value

        #expect(controller.manualRefreshTask == nil)
        #expect(refreshItem.isEnabled)
    }

    @Test
    func `only refresh uses a custom row while standard actions stay native`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings, updater: UpdateReadyUpdater())
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let updateItem = try #require(menu.items.first { $0.title == "Update ready, restart now?" })
        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        #expect(MenuDescriptor.MenuAction.installUpdate.systemImageName == "arrow.down.circle")
        #expect(updateItem.image != nil)
        #expect(refreshItem.view is any MenuCardHighlighting)
        #expect(refreshItem.action == nil)
        #expect(controller.isPersistentRefreshItem(refreshItem))
        #expect(refreshItem.keyEquivalent.isEmpty)
        #expect(refreshItem.keyEquivalentModifierMask.isEmpty)

        #expect(updateItem.view == nil)
        #expect(updateItem.action != nil)
        #expect(updateItem.target === controller)

        for (title, key) in [("Settings...", ","), ("About CodexBar", ""), ("Quit", "q")] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.view == nil)
            #expect(item.action != nil)
            #expect(item.target === controller)
            #expect(item.keyEquivalent == key)
            if !key.isEmpty {
                #expect(item.keyEquivalentModifierMask == [.command])
            }
        }
    }

    @Test
    func `persistent refresh row reflects scoped global and manual refresh state`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        #expect(controller.isPersistentRefreshItem(refreshItem))
        #expect(controller.persistentRefreshItems.allObjects.contains { $0 === refreshItem })
        #expect(refreshItem.isEnabled)

        controller.store.refreshingProviders.insert(.claude)
        controller.updatePersistentRefreshItemsEnabled()
        #expect(refreshItem.isEnabled)

        controller.store.refreshingProviders.insert(.codex)
        controller.updatePersistentRefreshItemsEnabled()
        #expect(!refreshItem.isEnabled)

        controller.store.refreshingProviders.removeAll()
        controller.store.isRefreshing = true
        controller.updatePersistentRefreshItemsEnabled()
        #expect(!refreshItem.isEnabled)

        controller.store.isRefreshing = false
        controller.manualRefreshProvider = .claude
        controller.manualRefreshTask = Task {}
        controller.updatePersistentRefreshItemsEnabled()
        #expect(!refreshItem.isEnabled)

        controller.manualRefreshTask = nil
        controller.manualRefreshProvider = nil
        controller.updatePersistentRefreshItemsEnabled()
        #expect(refreshItem.isEnabled)

        refreshItem.representedObject = "notRefresh"
        controller.manualRefreshTask = Task {}
        controller.updatePersistentRefreshItemsEnabled()
        #expect(refreshItem.isEnabled)
        #expect(!controller.persistentRefreshItems.allObjects.contains { $0 === refreshItem })
        controller.manualRefreshTask = nil
    }

    @Test
    func `refresh monitor follows refresh success and failure`() {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let monitor = controller.menuCardRefreshMonitor
        let fallback = MenuCardLiveSubtitle(text: "Fallback", style: .info)

        #expect(monitor.subtitle(for: .codex, fallback: fallback).style == .info)

        controller.store.isRefreshing = true
        #expect(monitor.subtitle(for: .codex, fallback: fallback).style == .loading)

        controller.store.isRefreshing = false
        monitor.isManualRefreshInFlight = true
        #expect(monitor.subtitle(for: .codex, fallback: fallback).style == .loading)
        monitor.isManualRefreshInFlight = false

        controller.store.isRefreshing = false
        let now = Date()
        controller.store.snapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        let success = monitor.subtitle(for: .codex, fallback: fallback)
        #expect(success.style == .info)
        #expect(success.text == UsageFormatter.updatedString(from: now, now: Date()))

        controller.store.errors[.codex] = "Refresh failed"
        let failure = monitor.subtitle(for: .codex, fallback: fallback)
        #expect(failure.style == .error)
        #expect(failure.text == "Refresh failed")

        monitor.isManualRefreshInFlight = true
        #expect(monitor.subtitle(for: .codex, fallback: fallback).style == .loading)
    }

    @Test
    func `scoped refresh monitor leaves unrelated providers unchanged`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let monitor = controller.menuCardRefreshMonitor
        let codexModel = try #require(controller.menuCardModel(for: .codex))
        let fallback = MenuCardLiveSubtitle(text: "Claude idle", style: .info)
        let expectedClaude = monitor.subtitle(for: .claude, fallback: fallback)

        monitor.beginManualRefresh(frozenModels: [.codex: codexModel], provider: .codex)
        defer { monitor.endManualRefresh() }

        #expect(monitor.isManualRefreshInFlight(for: .codex))
        #expect(!monitor.isManualRefreshInFlight(for: .claude))
        #expect(monitor.subtitle(for: .codex, fallback: fallback).style == .loading)
        let actualClaude = monitor.subtitle(for: .claude, fallback: fallback)
        #expect(actualClaude.text == expectedClaude.text)
        #expect(actualClaude.style == expectedClaude.style)
    }

    @Test
    func `refresh monitor updates compatible usage values after manual refresh completes`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let now = Date()
        controller.store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7200),
                resetDescription: nil),
            updatedAt: now)
        let fallback = try #require(controller.menuCardModel(for: .claude))
        controller.menuCardRefreshMonitor.isManualRefreshInFlight = true

        controller.store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 65,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 75,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7200),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(1))

        let inFlight = controller.menuCardRefreshMonitor.model(for: .claude, fallback: fallback)
        #expect(inFlight.metrics.map(\.percent) == fallback.metrics.map(\.percent))

        controller.menuCardRefreshMonitor.isManualRefreshInFlight = false
        let refreshed = controller.menuCardRefreshMonitor.model(for: .claude, fallback: fallback)
        let expected = try #require(controller.menuCardModel(for: .claude))

        #expect(refreshed.metrics.map(\.percent) == expected.metrics.map(\.percent))
        #expect(refreshed.metrics.map(\.percent) != fallback.metrics.map(\.percent))
    }

    @Test
    func `manual refresh keeps frozen quota even if menu rebuilds before completion`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let now = Date()
        for provider in [UsageProvider.claude, .codex] {
            controller.store.snapshots[provider] = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 21,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
            let frozen = try #require(controller.menuCardModel(for: provider))
            controller.menuCardRefreshMonitor.beginManualRefresh(frozenModels: [provider: frozen])

            controller.store.snapshots[provider] = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 18,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now.addingTimeInterval(1))
            let rebuiltFallback = try #require(controller.menuCardModel(for: provider))
            let inFlight = controller.menuCardRefreshMonitor.model(for: provider, fallback: rebuiltFallback)

            #expect(frozen.metrics.first?.percentLabel == "79% left")
            #expect(rebuiltFallback.metrics.first?.percentLabel == "82% left")
            #expect(inFlight.metrics.first?.percentLabel == "79% left")

            controller.menuCardRefreshMonitor.endManualRefresh()
            let completed = controller.menuCardRefreshMonitor.model(for: provider, fallback: frozen)
            #expect(completed.metrics.first?.percentLabel == "82% left")
        }
    }

    @Test
    func `manual refresh uses fallback when frozen quota layout is incompatible`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let now = Date()
        controller.store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 21,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        let frozen = try #require(controller.menuCardModel(for: .claude))
        controller.menuCardRefreshMonitor.beginManualRefresh(frozenModels: [.claude: frozen])

        controller.store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 18,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(1))
        let rebuiltFallback = try #require(controller.menuCardModel(for: .claude))
        let inFlight = controller.menuCardRefreshMonitor.model(for: .claude, fallback: rebuiltFallback)

        #expect(frozen.metrics.count == 1)
        #expect(rebuiltFallback.metrics.count == 2)
        #expect(inFlight.metrics.count == 2)
        #expect(inFlight.metrics.map(\.id) == rebuiltFallback.metrics.map(\.id))
    }

    @Test
    func `manual refresh preserves frozen quota when supplemental metric remains`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(
            settings: settings,
            account: AccountInfo(email: "test@example.com", plan: "pro"))
        let now = Date()
        controller.store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "test@example.com",
            codeReviewRemainingPercent: 88,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: now)
        controller.store.openAIDashboardAttachmentAuthorized = true
        controller.store.openAIDashboardRequiresLogin = false
        controller.store.snapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 21,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
        let frozen = try #require(controller.menuCardModel(for: .codex))
        controller.menuCardRefreshMonitor.beginManualRefresh(frozenModels: [.codex: frozen])

        controller.store.snapshots[.codex] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: now.addingTimeInterval(1))
        let fallback = try #require(controller.menuCardModel(for: .codex))
        let inFlight = controller.menuCardRefreshMonitor.model(for: .codex, fallback: fallback)

        #expect(frozen.metrics.count == 3)
        #expect(fallback.metrics.map(\.id) == ["code-review"])
        #expect(inFlight.metrics.map(\.id) == frozen.metrics.map(\.id))
        #expect(inFlight.metrics.first?.percentLabel == "79% left")
    }

    @Test
    func `manual refresh uses fallback when empty quota gains credit content`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(
            settings: settings,
            account: AccountInfo(email: "test@example.com", plan: "pro"))
        let now = Date()
        controller.store.snapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 21,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        let frozen = try #require(controller.menuCardModel(for: .codex))
        controller.menuCardRefreshMonitor.beginManualRefresh(frozenModels: [.codex: frozen])

        controller.store.snapshots[.codex] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: now.addingTimeInterval(1))
        controller.store.credits = CreditsSnapshot(
            remaining: 42,
            events: [],
            updatedAt: now.addingTimeInterval(1))
        let fallback = try #require(controller.menuCardModel(for: .codex))
        let inFlight = controller.menuCardRefreshMonitor.model(for: .codex, fallback: fallback)

        #expect(frozen.metrics.count == 1)
        #expect(fallback.metrics.isEmpty)
        #expect(fallback.creditsText != nil)
        #expect(inFlight.metrics.isEmpty)
        #expect(inFlight.creditsText == fallback.creditsText)
    }

    @Test
    func `manual refresh uses fallback when empty quota gains a placeholder`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let now = Date()
        controller.store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 21,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        let frozen = try #require(controller.menuCardModel(for: .claude))
        controller.menuCardRefreshMonitor.beginManualRefresh(frozenModels: [.claude: frozen])

        controller.store.snapshots.removeValue(forKey: .claude)
        let fallback = try #require(controller.menuCardModel(for: .claude))
        let inFlight = controller.menuCardRefreshMonitor.model(for: .claude, fallback: fallback)

        #expect(frozen.metrics.count == 1)
        #expect(fallback.metrics.isEmpty)
        #expect(fallback.placeholder != nil)
        #expect(inFlight.metrics.isEmpty)
        #expect(inFlight.placeholder == fallback.placeholder)
    }

    @Test
    func `refresh monitor updates single line credit balances`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(
            settings: settings,
            account: AccountInfo(email: "test@example.com", plan: "pro"))
        let now = Date()
        controller.store.snapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        controller.store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: now)
        let fallback = try #require(controller.menuCardModel(for: .codex))

        controller.store.credits = CreditsSnapshot(
            remaining: 42,
            events: [],
            updatedAt: now.addingTimeInterval(1))
        let refreshed = controller.menuCardRefreshMonitor.model(for: .codex, fallback: fallback)

        #expect(refreshed.creditsRemaining == 42)
        #expect(refreshed.creditsText != fallback.creditsText)
    }

    @Test
    func `refresh monitor preserves multiline workspace credit text`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        controller.store.snapshots[.amp] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            ampUsage: AmpUsageDetails(
                individualCredits: 12,
                workspaceBalances: [AmpWorkspaceBalance(name: "Team", remaining: 7)]),
            updatedAt: Date())
        let fallback = try #require(controller.menuCardModel(for: .amp))

        controller.store.snapshots[.amp] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            ampUsage: AmpUsageDetails(
                individualCredits: 10,
                workspaceBalances: [AmpWorkspaceBalance(name: "Team", remaining: 3)]),
            updatedAt: Date())
        let refreshed = controller.menuCardRefreshMonitor.model(for: .amp, fallback: fallback)

        #expect(refreshed.creditsText == fallback.creditsText)
    }

    @Test
    func `refresh monitor preserves tracked layout when refresh adds usage sections`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let fallback = try #require(controller.menuCardModel(for: .claude))
        #expect(fallback.metrics.isEmpty)

        controller.store.snapshots[.claude] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        let refreshed = controller.menuCardRefreshMonitor.model(for: .claude, fallback: fallback)

        #expect(refreshed.metrics.isEmpty)
        #expect(refreshed.placeholder == fallback.placeholder)
    }

    @Test
    func `refresh monitor preserves tracked layout when token error appears`() throws {
        let settings = self.makeSettings()
        settings.costUsageEnabled = true
        let controller = self.makeController(settings: settings)
        controller.store._setTokenSnapshotForTesting(Self.makeTokenSnapshot(), provider: .claude)
        let fallback = try #require(controller.menuCardModel(for: .claude))
        #expect(fallback.tokenUsage?.errorLine == nil)

        controller.store._setTokenErrorForTesting("New token usage error", provider: .claude)
        let refreshed = controller.menuCardRefreshMonitor.model(for: .claude, fallback: fallback)

        #expect(refreshed.tokenUsage?.errorLine == nil)
    }

    @Test
    func `refresh monitor preserves tracked layout when token error text changes`() throws {
        let settings = self.makeSettings()
        settings.costUsageEnabled = true
        let controller = self.makeController(settings: settings)
        controller.store._setTokenSnapshotForTesting(Self.makeTokenSnapshot(), provider: .claude)
        controller.store._setTokenErrorForTesting("Old token usage error", provider: .claude)
        let fallback = try #require(controller.menuCardModel(for: .claude))

        controller.store._setTokenErrorForTesting(
            "A longer replacement error that could occupy more lines",
            provider: .claude)
        let refreshed = controller.menuCardRefreshMonitor.model(for: .claude, fallback: fallback)

        #expect(refreshed.tokenUsage?.errorLine == "Old token usage error")
    }

    @Test
    func `live subtitle preserves canonical model error filtering`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(
            settings: settings,
            account: AccountInfo(email: "test@example.com", plan: "pro"))
        controller.store.errors[.codex] = UsageError.noRateLimitsFound.errorDescription
        let model = try #require(controller.menuCardModel(for: .codex))
        let fallback = MenuCardLiveSubtitle(text: "Fallback", style: .error)

        let liveSubtitle = controller.menuCardRefreshMonitor.subtitle(for: .codex, fallback: fallback)

        #expect(liveSubtitle.text == model.subtitleText)
        #expect(liveSubtitle.style == model.subtitleStyle)
        #expect(liveSubtitle.text != UsageError.noRateLimitsFound.errorDescription)
        #expect(liveSubtitle.style != .error)
    }

    @Test
    func `override cards keep their own subtitle`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        let liveModel = try #require(controller.menuCardModel(for: .codex))
        let overrideModel = try #require(controller.menuCardModel(
            for: .codex,
            errorOverride: "Account unavailable",
            forceOverrideCard: true))

        #expect(liveModel.usesLiveSubtitle)
        #expect(!overrideModel.usesLiveSubtitle)
        #expect(overrideModel.subtitleText == "Account unavailable")
    }

    @Test
    func `live failure keeps the measured card height`() throws {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)

        func fittingHeight(for model: UsageMenuCardView.Model) -> CGFloat {
            NSHostingView(rootView: UsageMenuCardView(model: model, width: 320)
                .environment(\.menuCardRefreshMonitor, controller.menuCardRefreshMonitor))
                .fittingSize.height
        }

        let idleModel = try #require(controller.menuCardModel(for: .codex))
        let idleHeight = fittingHeight(for: idleModel)
        controller.store.errors[.codex] = "Short error"
        let failureHeight = fittingHeight(for: idleModel)

        #expect(failureHeight == idleHeight)

        let errorModel = try #require(controller.menuCardModel(for: .codex))
        let errorHeight = fittingHeight(for: errorModel)
        controller.store.errors[.codex] =
            "Refresh failed with a much longer replacement message that must not resize the tracked menu"
        let replacementErrorHeight = fittingHeight(for: errorModel)
        controller.menuCardRefreshMonitor.isManualRefreshInFlight = true
        let retryHeight = fittingHeight(for: errorModel)

        #expect(replacementErrorHeight == errorHeight)
        let fallback = MenuCardLiveSubtitle(text: errorModel.subtitleText, style: errorModel.subtitleStyle)
        #expect(controller.menuCardRefreshMonitor.subtitle(for: .codex, fallback: fallback).style == .loading)
        #expect(retryHeight == errorHeight)
    }

    @Test
    func `manual refresh is suppressed after shutdown preparation`() {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        var requestCount = 0
        controller._test_manualRefreshOperation = {
            requestCount += 1
        }

        controller.prepareForAppShutdown()
        controller.refreshNow()

        #expect(requestCount == 0)
        #expect(controller.manualRefreshTask == nil)
        #expect(!controller.menuCardRefreshMonitor.isManualRefreshInFlight)
    }

    @Test
    func `repeated manual refresh clicks share one lifecycle`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)

        let gate = ManualRefreshGate()
        var requestCount = 0
        controller._test_manualRefreshOperation = {
            requestCount += 1
            await gate.wait()
        }

        controller.refreshNow()
        let task = try #require(controller.manualRefreshTask)
        controller.refreshNow()
        controller.refreshNow()
        await Task.yield()

        #expect(requestCount == 1)
        #expect(controller.menuCardRefreshMonitor.isManualRefreshInFlight)

        gate.resume()
        await task.value

        #expect(controller.manualRefreshTask == nil)
        #expect(!controller.menuCardRefreshMonitor.isManualRefreshInFlight)
    }

    @Test
    func `provider menu persistent refresh row and command R refresh only that provider`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnly([.claude, .codex], settings: settings)

        let controller = self.makeController(settings: settings)
        let menu = try #require(controller.makeMenu(for: .claude) as? StatusItemMenu)
        let codexMenu = try #require(controller.makeMenu(for: .codex) as? StatusItemMenu)
        controller.menuWillOpen(menu)
        controller.menuWillOpen(codexMenu)
        defer {
            controller.menuDidClose(codexMenu)
            controller.menuDidClose(menu)
        }

        let mouseGate = ManualRefreshGate()
        var requestCount = 0
        controller._test_manualRefreshOperation = {
            requestCount += 1
            await mouseGate.wait()
        }
        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        #expect(controller.isPersistentRefreshItem(refreshItem))
        controller.performPersistentRefreshAction(in: ObjectIdentifier(menu))
        for _ in 0..<20 where controller.manualRefreshTask == nil {
            await Task.yield()
        }
        let mouseTask = try #require(controller.manualRefreshTask)
        #expect(controller.manualRefreshProvider == .claude)
        #expect(controller.isRefreshActionInFlight(for: codexMenu))
        #expect(controller.isRefreshActionInFlight(for: NSMenu()))
        let codexRefreshItem = try #require(codexMenu.items.first { $0.title == "Refresh" })
        #expect(controller.isPersistentRefreshItem(codexRefreshItem))
        controller.performPersistentRefreshAction(in: ObjectIdentifier(codexMenu))
        await Task.yield()
        #expect(requestCount == 1)
        mouseGate.resume()
        await mouseTask.value

        let keyboardGate = ManualRefreshGate()
        controller._test_manualRefreshOperation = { await keyboardGate.wait() }
        #expect(try menu.performKeyEquivalent(with: self.keyEvent("r", keyCode: 15)))
        for _ in 0..<20 where controller.manualRefreshTask == nil {
            await Task.yield()
        }
        let keyboardTask = try #require(controller.manualRefreshTask)
        #expect(controller.manualRefreshProvider == .claude)
        keyboardGate.resume()
        await keyboardTask.value
    }

    @Test
    func `provider menu does not replace matching scoped refresh`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnly([.claude, .codex], settings: settings)

        let controller = self.makeController(settings: settings)
        let menu = try #require(controller.makeMenu(for: .claude) as? StatusItemMenu)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        controller.store.refreshingProviders.insert(.claude)
        var requestCount = 0
        controller._test_manualRefreshOperation = { requestCount += 1 }

        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        #expect(controller.isPersistentRefreshItem(refreshItem))
        controller.performPersistentRefreshAction(in: ObjectIdentifier(menu))
        #expect(try menu.performKeyEquivalent(with: self.keyEvent("r", keyCode: 15)))
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(requestCount == 0)
        #expect(controller.manualRefreshTask == nil)
        #expect(controller.manualRefreshProvider == nil)
    }

    @Test
    func `merged overview refreshes globally while selected provider stays scoped`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnly([.claude, .codex], settings: settings)
        settings.mergedMenuLastSelectedWasOverview = true

        let controller = self.makeController(settings: settings)
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let overviewGate = ManualRefreshGate()
        controller._test_manualRefreshOperation = { await overviewGate.wait() }
        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        #expect(controller.isPersistentRefreshItem(refreshItem))
        controller.performPersistentRefreshAction(in: ObjectIdentifier(menu))
        for _ in 0..<20 where controller.manualRefreshTask == nil {
            await Task.yield()
        }
        let overviewTask = try #require(controller.manualRefreshTask)
        #expect(controller.manualRefreshProvider == nil)
        overviewGate.resume()
        await overviewTask.value

        settings.mergedMenuLastSelectedWasOverview = false
        controller.selectedMenuProvider = .claude
        let providerGate = ManualRefreshGate()
        controller._test_manualRefreshOperation = { await providerGate.wait() }
        #expect(try menu.performKeyEquivalent(with: self.keyEvent("r", keyCode: 15)))
        for _ in 0..<20 where controller.manualRefreshTask == nil {
            await Task.yield()
        }
        let providerTask = try #require(controller.manualRefreshTask)
        #expect(controller.manualRefreshProvider == .claude)
        providerGate.resume()
        await providerTask.value
    }

    @Test
    func `provider scoped refresh updates status and widget snapshot`() async {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        self.enableOnly([.synthetic], settings: settings)

        let controller = self.makeController(settings: settings)
        controller.store._test_providerRefreshOverride = { _ in }
        controller.store._test_providerStatusFetchOverride = { provider in
            #expect(provider == .synthetic)
            return ProviderStatus(indicator: .none, description: "Operational", updatedAt: Date())
        }
        var savedSnapshots = 0
        controller.store._test_widgetSnapshotSaveOverride = { _ in
            savedSnapshots += 1
        }

        await controller.performStoreRefresh(
            for: .synthetic,
            refreshOpenMenusWhenComplete: false,
            interaction: .userInitiated)
        _ = await controller.store.widgetSnapshotPersistTask?.result

        #expect(controller.store.statuses[.synthetic]?.description == "Operational")
        #expect(savedSnapshots == 1)
    }

    @Test
    func `failed manual refresh returns persistent item to enabled and surfaces error`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        let gate = ManualRefreshGate()

        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.store.errors[.codex] = "Refresh failed"
        }

        controller.refreshNow()
        let task = try #require(controller.manualRefreshTask)
        #expect(!refreshItem.isEnabled)

        gate.resume()
        await task.value

        #expect(controller.manualRefreshTask == nil)
        #expect(refreshItem.isEnabled)
        let fallback = MenuCardLiveSubtitle(text: "Fallback", style: .info)
        #expect(controller.menuCardRefreshMonitor.subtitle(for: .codex, fallback: fallback).style == .error)
    }

    @Test
    func `status item menu intercepts persistent shortcuts without native item selection`() throws {
        let menu = StatusItemMenu()
        let recorder = RefreshShortcutRecorder()
        menu.persistentActionDelegate = recorder

        #expect(try menu.performKeyEquivalent(with: self.keyEvent("r", keyCode: 15)) == true)
        #expect(try menu.performKeyEquivalent(with: self.keyEvent(",", keyCode: 43)) == true)
        #expect(try menu.performKeyEquivalent(with: self.keyEvent("q", keyCode: 12)) == true)

        #expect(recorder.refreshCount == 1)
        #expect(recorder.refreshMenuIDs == [ObjectIdentifier(menu)])
        #expect(recorder.settingsCount == 1)
        #expect(recorder.quitCount == 1)
    }

    private func keyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode))
    }
}

extension StatusMenuPersistentRefreshTests {
    @Test
    func `refresh row metrics match tuned native-style values`() {
        let metrics = PersistentRefreshRowMetrics.defaults
        #expect(metrics.rowHeight == 24)
        #expect(metrics.selectionHorizontalInset == 5)
        #expect(metrics.selectionVerticalInset == 0)
        #expect(metrics.selectionCornerRadius == 7)
        #expect(metrics.leadingPadding == 13)
        #expect(metrics.trailingPadding == 8)
        #expect(metrics.iconWidth == 17)
        #expect(metrics.iconSymbolPointSize == 11)
        #expect(metrics.iconTitleSpacing == 4.5)
        #expect(metrics.shortcutFontSize == 13)
        #expect(metrics.shortcutXOffset == -12)
        #expect(metrics.shortcutYOffset == 0)
    }

    @Test
    func `refresh shortcut display has stable native-style column`() throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        let refreshView = try #require(refreshItem.view as? PersistentRefreshMenuView)
        refreshView.applySize(width: 320, height: PersistentRefreshRowMetrics.defaults.rowHeight)
        refreshView.layoutSubtreeIfNeeded()

        let shortcutField = try #require(
            refreshView.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "⌘ R" })
        #expect(shortcutField.alignment == .left)
        #expect(shortcutField.lineBreakMode == .byClipping)
        #expect(shortcutField.frame.width >= 40)
        let shortcutFont = try #require(shortcutField.font)
        #expect(abs(shortcutFont.pointSize - PersistentRefreshRowMetrics.defaults.shortcutFontSize) < 0.001)

        let iconView = try #require(refreshView.subviews.compactMap { $0 as? NSImageView }.first)
        let titleField = try #require(
            refreshView.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Refresh" })
        #expect(iconView.frame.minX == PersistentRefreshRowMetrics.defaults.leadingPadding)
        #expect(titleField.frame.minX == PersistentRefreshRowMetrics.defaults.leadingPadding
            + PersistentRefreshRowMetrics.defaults.iconWidth
            + PersistentRefreshRowMetrics.defaults.iconTitleSpacing)
        #expect(iconView.frame.width == PersistentRefreshRowMetrics.defaults.iconWidth)
        #expect(iconView.frame.height == PersistentRefreshRowMetrics.defaults.iconWidth)
    }

    @Test
    func `refresh row width follows final rendered menu width`() {
        let settings = self.makeSettings()
        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let metrics = PersistentRefreshRowMetrics.defaults
        let refreshView = PersistentRefreshMenuView(
            title: "Refresh",
            systemImageName: "arrow.clockwise",
            shortcutText: "⌘ R")
        refreshView.applySize(width: StatusItemController.menuCardBaseWidth, height: metrics.rowHeight)
        refreshView.frame.origin.x = 4

        let refreshItem = NSMenuItem()
        refreshItem.title = "Refresh"
        refreshItem.view = refreshView

        let wideNativeItem = NSMenuItem(
            title: String(repeating: "W", count: 60),
            action: nil,
            keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(refreshItem)
        menu.addItem(wideNativeItem)

        let expectedWidth = controller.renderedMenuWidth(for: menu)
        #expect(expectedWidth > StatusItemController.menuCardBaseWidth)

        controller.refreshMenuCardHeights(in: menu)

        #expect(abs(refreshView.frame.width - expectedWidth) <= 0.5)
        #expect(refreshView.frame.origin == .zero)
        #expect(refreshView.frame.height == metrics.rowHeight)
    }
}
