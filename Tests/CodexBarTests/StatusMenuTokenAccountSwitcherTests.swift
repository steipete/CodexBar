import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

@MainActor
final class StatusMenuTokenAccountSwitcherTests: XCTestCase {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    private func makeSettings() -> SettingsStore {
        let settings = testSettingsStore(
            suiteName: "StatusMenuTokenAccountSwitcherTests",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    private func enableOnlyClaude(_ settings: SettingsStore) {
        self.enableOnly(.claude, settings)
    }

    private func enableOnly(_ enabledProvider: UsageProvider, _ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == enabledProvider)
        }
    }

    private func representedIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }
    }

    private func installBlockingClaudeProvider(on store: UsageStore, blocker: BlockingTokenAccountFetchStrategy) {
        let baseSpec = store.providerSpecs[.claude]!
        store.providerSpecs[.claude] = Self.makeClaudeProviderSpec(baseSpec: baseSpec) {
            try await blocker.awaitResult()
        }
    }

    private static func makeClaudeProviderSpec(
        baseSpec: ProviderSpec,
        loader: @escaping @Sendable () async throws -> UsageSnapshot) -> ProviderSpec
    {
        let baseDescriptor = baseSpec.descriptor
        let strategy = StatusMenuTokenAccountFetchStrategy(loader: loader)
        let descriptor = ProviderDescriptor(
            id: .claude,
            metadata: baseDescriptor.metadata,
            branding: baseDescriptor.branding,
            tokenCost: baseDescriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth],
                pipeline: ProviderFetchPipeline { _ in [strategy] }),
            cli: baseDescriptor.cli)
        return ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)
    }

    private func snapshot(percent: Double = 12) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: percent,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(300),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "claude@example.com",
                accountOrganization: nil,
                loginMethod: "OAuth"))
    }

    func test_tokenAccountMenuSelectionRefreshesProviderWhileGlobalRefreshIsActive() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyClaude(settings)
        settings.addTokenAccount(provider: .claude, label: "Primary", token: "Bearer sk-ant-oat-primary")
        settings.addTokenAccount(provider: .claude, label: "Secondary", token: "Bearer sk-ant-oat-secondary")
        settings.setActiveTokenAccountIndex(0, for: .claude)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let blocker = BlockingTokenAccountFetchStrategy()
        self.installBlockingClaudeProvider(on: store, blocker: blocker)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let refreshTask = Task { @MainActor in
            await store.refresh()
        }
        await blocker.waitUntilStarted(count: 1)
        XCTAssertTrue(store.isRefreshing)

        let menu = controller.makeMenu()
        defer { withExtendedLifetime(menu) {} }
        controller.menuWillOpen(menu)
        let switcher = try XCTUnwrap(menu.items.compactMap { $0.view as? TokenAccountSwitcherView }.first)

        let selectionTask = try XCTUnwrap(switcher._test_select(index: 1))
        XCTAssertEqual(settings.tokenAccountsData(for: .claude)?.clampedActiveIndex(), 1)
        for _ in 0..<40 {
            await Task.yield()
        }
        let startedBeforeDrain = await blocker.startedCallCount()
        XCTAssertEqual(startedBeforeDrain, 1)

        await blocker.resumeAll(with: .success(self.snapshot(percent: 17)))
        await blocker.waitUntilStarted(count: 2)
        await selectionTask.value
        await refreshTask.value
        let startedCallCount = await blocker.startedCallCount()
        XCTAssertGreaterThanOrEqual(startedCallCount, 2)
    }

    func test_multiAccountSegmentedLayoutShowsCopilotSwitcher() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .segmented
        self.enableOnly(.copilot, settings)
        settings.addTokenAccount(provider: .copilot, label: "Primary", token: "gh_primary")
        settings.addTokenAccount(provider: .copilot, label: "Secondary", token: "gh_secondary")

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

        let menu = controller.makeMenu(for: .copilot)
        controller.menuWillOpen(menu)

        _ = try XCTUnwrap(menu.items.compactMap { $0.view as? TokenAccountSwitcherView }.first)
        XCTAssertEqual(self.representedIDs(in: menu).filter { $0.hasPrefix("menuCard") }, ["menuCard"])
    }

    func test_multiAccountStackedLayoutShowsCopilotCards() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
        self.enableOnly(.copilot, settings)
        settings.addTokenAccount(provider: .copilot, label: "Primary", token: "gh_primary")
        settings.addTokenAccount(provider: .copilot, label: "Secondary", token: "gh_secondary")
        let accounts = settings.tokenAccounts(for: .copilot)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.accountSnapshots[.copilot] = accounts.enumerated().map { index, account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(percent: Double(10 + index)),
                error: nil,
                sourceLabel: "test")
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .copilot)
        controller.menuWillOpen(menu)

        XCTAssertNil(menu.items.compactMap { $0.view as? TokenAccountSwitcherView }.first)
        XCTAssertEqual(self.representedIDs(in: menu).filter { $0.hasPrefix("menuCard") }, ["menuCard-0", "menuCard-1"])
    }

    func test_multiAccountStackedRefreshStartsAccountFetchesConcurrently() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
        self.enableOnlyClaude(settings)
        settings.addTokenAccount(provider: .claude, label: "Primary", token: "Bearer sk-ant-oat-primary")
        settings.addTokenAccount(provider: .claude, label: "Secondary", token: "Bearer sk-ant-oat-secondary")

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let blocker = BlockingTokenAccountFetchStrategy()
        self.installBlockingClaudeProvider(on: store, blocker: blocker)

        let refreshTask = Task { @MainActor in
            await store.refreshProvider(.claude)
        }

        await blocker.waitUntilStarted(count: 2)
        let startedBeforeResume = await blocker.startedCallCount()
        XCTAssertEqual(startedBeforeResume, 2)

        await blocker.resumeAll(with: .success(self.snapshot(percent: 17)))
        await refreshTask.value
        XCTAssertEqual(store.accountSnapshots[.claude]?.count, 2)
    }

    func test_multiAccountStackedLayoutIgnoresStaleSnapshotsAndKeepsMenuCapped() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
        self.enableOnly(.copilot, settings)
        for index in 0..<8 {
            settings.addTokenAccount(provider: .copilot, label: "Account \(index)", token: "gh_\(index)")
        }
        settings.setActiveTokenAccountIndex(7, for: .copilot)
        let accounts = settings.tokenAccounts(for: .copilot)
        let staleAccounts = (0..<2).map { index in
            ProviderTokenAccount(
                id: UUID(),
                label: "Removed \(index)",
                token: "stale_\(index)",
                addedAt: TimeInterval(index),
                lastUsed: nil)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let staleSnapshots = staleAccounts.enumerated().map { index, account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(percent: Double(70 + index)),
                error: nil,
                sourceLabel: "stale")
        }
        let currentSnapshots = accounts.enumerated().map { index, account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(percent: Double(10 + index)),
                error: nil,
                sourceLabel: "current")
        }
        store.accountSnapshots[.copilot] = staleSnapshots + currentSnapshots
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .copilot)
        controller.menuWillOpen(menu)

        XCTAssertNil(menu.items.compactMap { $0.view as? TokenAccountSwitcherView }.first)
        XCTAssertEqual(
            self.representedIDs(in: menu).filter { $0.hasPrefix("menuCard") },
            ["menuCard-0", "menuCard-1", "menuCard-2", "menuCard-3", "menuCard-4", "menuCard-5"])
    }

    func test_tokenAccountSwitchDefersOpenMenuRebuildUntilAfterSwitcherAction() async throws {
        self.disableMenuCardsForTesting()
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.setMenuRefreshEnabledForTesting(false) }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.multiAccountMenuLayout = .segmented
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .claude || provider == .codex)
        }
        settings.addTokenAccount(provider: .claude, label: "Primary", token: "Bearer sk-ant-oat-primary")
        settings.addTokenAccount(provider: .claude, label: "Secondary", token: "Bearer sk-ant-oat-secondary")
        settings.setActiveTokenAccountIndex(0, for: .claude)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let blocker = BlockingTokenAccountFetchStrategy()
        self.installBlockingClaudeProvider(on: store, blocker: blocker)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let switcher = try XCTUnwrap(menu.items.compactMap { $0.view as? TokenAccountSwitcherView }.first)

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        let selectionTask = try XCTUnwrap(switcher._test_select(index: 1))

        XCTAssertEqual(rebuildCount, 0)
        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(rebuildCount, 1)

        await blocker.waitUntilStarted(count: 1)
        await blocker.resumeAll(with: .success(self.snapshot(percent: 17)))
        await selectionTask.value
        for _ in 0..<20 where rebuildCount < 2 {
            await Task.yield()
        }
        XCTAssertEqual(rebuildCount, 2)
    }

    func test_tokenAccountSwitchUsesSelectedAccountCacheWhileRefreshIsInFlight() async throws {
        self.disableMenuCardsForTesting()
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { StatusItemController.setMenuRefreshEnabledForTesting(false) }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .segmented
        self.enableOnlyClaude(settings)
        settings.addTokenAccount(provider: .claude, label: "Primary", token: "Bearer sk-ant-oat-primary")
        settings.addTokenAccount(provider: .claude, label: "Secondary", token: "Bearer sk-ant-oat-secondary")
        settings.setActiveTokenAccountIndex(0, for: .claude)
        let accounts = settings.tokenAccounts(for: .claude)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.snapshots[.claude] = self.snapshot(percent: 11)
        store.lastKnownResetSnapshots[.claude] = self.snapshot(percent: 11)
        store.errors[.claude] = "primary-error"
        store.lastSourceLabels[.claude] = "primary-cache"
        store.accountSnapshots[.claude] = [
            TokenAccountUsageSnapshot(
                account: accounts[0],
                snapshot: self.snapshot(percent: 11),
                error: nil,
                sourceLabel: "primary-cache"),
            TokenAccountUsageSnapshot(
                account: accounts[1],
                snapshot: self.snapshot(percent: 72),
                error: nil,
                sourceLabel: "secondary-cache"),
        ]
        let blocker = BlockingTokenAccountFetchStrategy()
        self.installBlockingClaudeProvider(on: store, blocker: blocker)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        let switcher = try XCTUnwrap(menu.items.compactMap { $0.view as? TokenAccountSwitcherView }.first)

        let selectionTask = try XCTUnwrap(switcher._test_select(index: 1))

        XCTAssertEqual(store.snapshot(for: .claude)?.primary?.usedPercent, 72)
        XCTAssertEqual(store.lastKnownResetSnapshots[.claude]?.primary?.usedPercent, 72)
        XCTAssertNil(store.errors[.claude])
        XCTAssertEqual(store.sourceLabel(for: .claude), "secondary-cache")

        await blocker.waitUntilStarted(count: 1)
        await blocker.resumeAll(with: .success(self.snapshot(percent: 45)))
        await selectionTask.value
    }

    func test_tokenAccountSwitchClearsPreviousAccountSnapshotWithoutSelectedCache() async throws {
        self.disableMenuCardsForTesting()

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .segmented
        self.enableOnlyClaude(settings)
        settings.addTokenAccount(provider: .claude, label: "Primary", token: "Bearer sk-ant-oat-primary")
        settings.addTokenAccount(provider: .claude, label: "Secondary", token: "Bearer sk-ant-oat-secondary")
        settings.setActiveTokenAccountIndex(0, for: .claude)
        let accounts = settings.tokenAccounts(for: .claude)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.snapshots[.claude] = self.snapshot(percent: 11)
        store.lastKnownResetSnapshots[.claude] = self.snapshot(percent: 11)
        store.errors[.claude] = "primary-error"
        store.lastSourceLabels[.claude] = "primary-cache"
        store.accountSnapshots[.claude] = [
            TokenAccountUsageSnapshot(
                account: accounts[0],
                snapshot: self.snapshot(percent: 11),
                error: nil,
                sourceLabel: "primary-cache"),
        ]
        let blocker = BlockingTokenAccountFetchStrategy()
        self.installBlockingClaudeProvider(on: store, blocker: blocker)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        let switcher = try XCTUnwrap(menu.items.compactMap { $0.view as? TokenAccountSwitcherView }.first)

        let selectionTask = try XCTUnwrap(switcher._test_select(index: 1))

        XCTAssertNil(store.snapshot(for: .claude))
        XCTAssertNil(store.lastKnownResetSnapshots[.claude])
        XCTAssertNil(store.errors[.claude])
        XCTAssertNil(store.lastSourceLabels[.claude])

        await blocker.waitUntilStarted(count: 1)
        await blocker.resumeAll(with: .success(self.snapshot(percent: 45)))
        await selectionTask.value
    }
}

private struct StatusMenuTokenAccountFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot

    var id: String {
        "status-menu-token-account-test"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.loader()
        return self.makeResult(usage: snapshot, sourceLabel: "status-menu-token-account-test")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private actor BlockingTokenAccountFetchStrategy {
    private var waiters: [CheckedContinuation<Result<UsageSnapshot, Error>, Never>] = []
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resolvedResult: Result<UsageSnapshot, Error>?
    private var startedCount = 0

    func awaitResult() async throws -> UsageSnapshot {
        if let resolvedResult {
            self.startedCount += 1
            self.resumeStartedWaiters()
            return try resolvedResult.get()
        }
        let result = await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
            self.startedCount += 1
            self.resumeStartedWaiters()
        }
        return try result.get()
    }

    func waitUntilStarted(count: Int) async {
        if self.startedCount >= count { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append((count: count, continuation: continuation))
        }
    }

    func startedCallCount() -> Int {
        self.startedCount
    }

    func resumeAll(with result: Result<UsageSnapshot, Error>) {
        self.resolvedResult = result
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }

    private func resumeStartedWaiters() {
        let ready = self.startedWaiters.filter { self.startedCount >= $0.count }
        self.startedWaiters.removeAll { self.startedCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}
