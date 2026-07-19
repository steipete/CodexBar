import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemControllerShutdownTests {
    @Test
    func `app shutdown closes tracked menus and removes status items`() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = !SettingsStore.isRunningTests
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let registry = ProviderRegistry.shared
        if let codexMetadata = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        }
        if let claudeMetadata = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        }

        let environment = Self.isolatedEnvironment()
        let fetcher = UsageFetcher(environment: environment)
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.menuRefreshTasks[key] = Task { try? await Task.sleep(for: .seconds(30)) }
        controller.menuReadinessSignatures[key] = "readiness"
        controller.menuIdentitySignatures[key] = "identity"
        controller.nativeHighlightDeferredMenuRebuilds[key] = .init(provider: .codex)
        controller.pendingMenuBaselineResyncs.insert(key)

        #expect(controller.openMenus[key] === menu)
        #expect(controller.mergedMenu != nil)
        #expect(controller.statusItem.menu === controller.mergedMenu)

        controller.prepareForAppShutdown()
        controller.prepareForAppShutdown()

        #expect(controller.hasPreparedForAppShutdown)
        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuRefreshTasks.isEmpty)
        #expect(controller.menuReadinessSignatures.isEmpty)
        #expect(controller.menuIdentitySignatures.isEmpty)
        #expect(controller.nativeHighlightDeferredMenuRebuilds.isEmpty)
        #expect(controller.pendingMenuBaselineResyncs.isEmpty)
        #expect(controller.providerSwitcherShortcutEventMonitor == nil)
        #expect(controller.statusItem.menu == nil)
        #expect(controller.statusItems.isEmpty)
        #expect(controller.providerMenus.isEmpty)
        #expect(controller.mergedMenu == nil)
    }

    @Test
    func `status menu quit defers shutdown until menu tracking can unwind`() {
        let controller = self.makeController()
        defer {
            StatusItemController.menuCardRenderingEnabled = !SettingsStore.isRunningTests
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)

        var scheduledTermination: (@MainActor () -> Void)?
        var didTerminate = false
        controller.scheduleQuitTermination = { operation in
            scheduledTermination = operation
        }
        controller.terminateApplicationForQuit = {
            didTerminate = true
        }

        controller.quit()

        #expect(scheduledTermination != nil)
        #expect(!controller.hasPreparedForAppShutdown)
        #expect(!didTerminate)
        #expect(controller.openMenus[key] === menu)

        scheduledTermination?()

        #expect(controller.hasPreparedForAppShutdown)
        #expect(controller.openMenus.isEmpty)
        #expect(controller.statusItem.menu == nil)
        #expect(didTerminate)
    }

    @Test
    func `app shutdown cancels forced enrichment`() async {
        let controller = self.makeController()
        defer {
            StatusItemController.menuCardRenderingEnabled = !SettingsStore.isRunningTests
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }
        controller.settings.statusChecksEnabled = false
        controller.settings.costUsageEnabled = true
        controller.settings.openAIWebAccessEnabled = false
        controller.settings.codexCookieSource = .off
        let tokenTail = CancellationAwareTokenTail()

        controller.store._test_providerRefreshOverride = { _ in }
        controller.store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        controller.store._test_tokenUsageRefreshOverride = { _, _ in
            await tokenTail.run()
        }
        defer {
            controller.store._test_providerRefreshOverride = nil
            controller.store._test_codexCreditsLoaderOverride = nil
            controller.store._test_tokenUsageRefreshOverride = nil
        }

        controller.refreshNow()
        let didStartTokenTail = await tokenTail.waitUntilStarted()
        #expect(didStartTokenTail)
        guard didStartTokenTail else {
            controller.prepareForAppShutdown()
            return
        }
        await controller.manualRefreshTasks[.global]?.value
        let enrichmentTask = controller.store.forcedRefreshEnrichmentTask
        let requiredRefresh = Task { @MainActor in
            await controller.store.refreshForSettingsChange()
        }
        for _ in 0..<100 where controller.store.requiredRefreshTask == nil {
            await Task.yield()
        }

        #expect(controller.store.hasForcedRefreshEnrichmentInFlight)
        #expect(controller.store.requiredRefreshTask != nil)
        controller.prepareForAppShutdown()
        await enrichmentTask?.value
        await requiredRefresh.value

        #expect(await tokenTail.wasCancelled())
        #expect(!controller.store.hasForcedRefreshEnrichmentInFlight)
        #expect(controller.store.forcedRefreshEnrichmentTask == nil)
        #expect(controller.store.pendingForcedRefreshEnrichmentTask == nil)
        #expect(controller.store.requiredRefreshTask == nil)
        #expect(controller.store.pendingRequiredRefreshRequest == nil)
        #expect(controller.store.openAIDashboardRefreshTask == nil)
        #expect(controller.store.tokenRefreshInFlight.isEmpty)
    }

    @Test
    func `app shutdown cancels active and pending forced enrichment without promotion`() async {
        let controller = self.makeController()
        defer {
            StatusItemController.menuCardRenderingEnabled = !SettingsStore.isRunningTests
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }
        controller.settings.statusChecksEnabled = false
        controller.settings.costUsageEnabled = true
        controller.settings.openAIWebAccessEnabled = false
        controller.settings.codexCookieSource = .off
        let tokenTail = CancellationAwareTokenTail()

        controller.store._test_providerRefreshOverride = { _ in }
        controller.store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        controller.store._test_tokenUsageRefreshOverride = { _, _ in
            await tokenTail.run()
        }
        defer {
            controller.store._test_providerRefreshOverride = nil
            controller.store._test_codexCreditsLoaderOverride = nil
            controller.store._test_tokenUsageRefreshOverride = nil
        }

        controller.refreshNow()
        let didStartTokenTail = await tokenTail.waitUntilStarted(count: 1)
        #expect(didStartTokenTail)
        guard didStartTokenTail else {
            controller.prepareForAppShutdown()
            return
        }
        await controller.manualRefreshTasks[.global]?.value

        await controller.store.refresh(enrichmentMode: .forcedBackground)
        let activeTask = controller.store.forcedRefreshEnrichmentTask
        let pendingTask = controller.store.pendingForcedRefreshEnrichmentTask
        #expect(activeTask != nil)
        #expect(pendingTask != nil)

        controller.prepareForAppShutdown()
        await activeTask?.value
        await pendingTask?.value

        #expect(await tokenTail.startedCount() == 1)
        #expect(await tokenTail.cancelledCount() == 1)
        #expect(pendingTask?.isCancelled == true)
        #expect(!controller.store.hasForcedRefreshEnrichmentInFlight)
        #expect(controller.store.forcedRefreshEnrichmentTask == nil)
        #expect(controller.store.pendingForcedRefreshEnrichmentTask == nil)
    }

    private func makeController() -> StatusItemController {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        if let codexMetadata = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        }

        let environment = Self.isolatedEnvironment()
        let fetcher = UsageFetcher(environment: environment)
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        return StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func makeSettings() -> SettingsStore {
        testSettingsStore(suiteName: "StatusItemControllerShutdownTests")
    }

    private static func isolatedEnvironment() -> [String: String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
    }
}

private actor CancellationAwareTokenTail {
    private var started = 0
    private var cancelled = 0

    func run() async {
        self.started += 1
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            self.cancelled += 1
        } catch {}
    }

    func waitUntilStarted(count: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.started < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func wasCancelled() -> Bool {
        self.cancelled > 0
    }

    func startedCount() -> Int {
        self.started
    }

    func cancelledCount() -> Int {
        self.cancelled
    }
}
