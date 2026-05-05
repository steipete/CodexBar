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

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuTokenAccountSwitcherTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private func enableOnlyClaude(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
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
            statusBar: self.makeStatusBarForTesting())
        defer { withExtendedLifetime(controller) {} }

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
        await blocker.waitUntilStarted(count: 2)
        XCTAssertEqual(settings.tokenAccountsData(for: .claude)?.clampedActiveIndex(), 1)

        await blocker.resumeAll(with: .success(self.snapshot(percent: 17)))
        await selectionTask.value
        await refreshTask.value
        let startedCallCount = await blocker.startedCallCount()
        XCTAssertGreaterThanOrEqual(startedCallCount, 2)
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
        self.startedCount += 1
        self.resumeStartedWaiters()
        if let resolvedResult {
            return try resolvedResult.get()
        }
        let result = await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
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
