import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexAccountScopedRefreshTests {
    @Test
    func `account transition invalidates codex scoped state and preserves token usage`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-invalidate")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        let staleSnapshot = self.codexSnapshot(email: "alpha@example.com", usedPercent: 10)
        let staleCredits = self.credits(remaining: 42)
        let staleDashboard = self.dashboard(email: "alpha@example.com", creditsRemaining: 42, usedPercent: 20)
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 120,
            sessionCostUSD: 1.2,
            last30DaysTokens: 900,
            last30DaysCostUSD: 9.0,
            daily: [],
            updatedAt: Date())
        var widgetSnapshots: [WidgetSnapshot] = []

        store._setSnapshotForTesting(staleSnapshot, provider: .codex)
        store.credits = staleCredits
        store.lastCreditsSnapshot = staleCredits
        store.lastCreditsSnapshotAccountKey = "alpha@example.com"
        store.openAIDashboard = staleDashboard
        store.lastOpenAIDashboardSnapshot = staleDashboard
        store.lastOpenAIDashboardTargetEmail = "alpha@example.com"
        store._setTokenSnapshotForTesting(tokenSnapshot, provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")

        let didInvalidate = store.prepareCodexAccountScopedRefreshIfNeeded()
        await store.widgetSnapshotPersistTask?.value

        #expect(didInvalidate)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.credits == nil)
        #expect(store.lastCreditsSnapshot == nil)
        #expect(store.lastCreditsSnapshotAccountKey == nil)
        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardSnapshot == nil)
        #expect(store.tokenSnapshots[.codex] == tokenSnapshot)
        #expect(widgetSnapshots.count == 1)
        #expect(widgetSnapshots[0].entries.contains(where: { $0.provider == .codex }) == false)
    }

    @Test
    func `first switch invalidates after codex refresh seeds the previous account guard`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-first-switch")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        self.installImmediateCodexProvider(
            on: store,
            snapshot: self.codexSnapshot(email: "alpha@example.com", usedPercent: 10))

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "alpha@example.com")

        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")

        let didInvalidate = store.prepareCodexAccountScopedRefreshIfNeeded()

        #expect(didInvalidate)
        #expect(store.snapshots[.codex] == nil)
    }

    @Test
    func `stale codex usage success is discarded after account switch`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-stale-success")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `stale codex usage failure does not clear newer account snapshot`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-stale-failure")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")
        let freshSnapshot = self.codexSnapshot(email: "beta@example.com", usedPercent: 5)
        store._setSnapshotForTesting(freshSnapshot, provider: .codex)
        await blocker.resume(with: .failure(TestRefreshError(message: "stale failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "beta@example.com")
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `credits fallback only reuses cache for the same codex account`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-credits")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        let cachedCredits = self.credits(remaining: 12)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 10), provider: .codex)
        store.lastCreditsSnapshot = cachedCredits
        store.lastCreditsSnapshotAccountKey = "alpha@example.com"
        store._test_codexCreditsLoaderOverride = {
            throw TestRefreshError(message: "Codex credits data not available yet")
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        await store.refreshCreditsIfNeeded()
        #expect(store.credits == cachedCredits)
        #expect(store.lastCreditsError == nil)

        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")
        store._setSnapshotForTesting(self.codexSnapshot(email: "beta@example.com", usedPercent: 10), provider: .codex)

        await store.refreshCreditsIfNeeded()
        #expect(store.credits == nil)
        #expect(store.lastCreditsError == "Codex credits are still loading; will retry shortly.")
    }

    @Test
    func `credits refresh returns quickly when no live codex account is available`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-credits-no-live-account")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-credits-no-live-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = nil
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = self.makeUsageStore(settings: settings)
        var loaderCalled = false
        store._test_codexCreditsLoaderOverride = {
            loaderCalled = true
            return self.credits(remaining: 1)
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let startedAt = ContinuousClock.now
        await store.refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: Date())
        let elapsed = startedAt.duration(to: .now)

        #expect(loaderCalled == false)
        #expect(elapsed < .seconds(2))
    }

    @Test
    func `stale dashboard apply is discarded after account switch`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.currentCodexAccountScopedRefreshGuard()
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")

        await store.applyOpenAIDashboard(
            self.dashboard(email: "alpha@example.com", creditsRemaining: 11, usedPercent: 35),
            targetEmail: "alpha@example.com",
            expectedGuard: expectedGuard,
            allowCodexUsageBackfill: true)

        #expect(store.openAIDashboard == nil)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.credits == nil)
    }

    @Test
    func `dashboard refresh can seed unknown live codex account`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard-seed-unknown-live")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-seed-unknown-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = nil
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = self.makeUsageStore(settings: settings)
        store.lastKnownLiveSystemCodexEmail = nil
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            self.dashboard(email: "seeded@example.com", creditsRemaining: 33, usedPercent: 12)
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let expectedGuard = store.currentCodexAccountScopedRefreshGuard()
        #expect(expectedGuard.source == .liveSystem)
        #expect(expectedGuard.accountKey == nil)

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(store.openAIDashboard?.signedInEmail == "seeded@example.com")
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "seeded@example.com")
        #expect(store.credits?.remaining == 33)
        #expect(store.lastCreditsSnapshotAccountKey == "seeded@example.com")
        #expect(store.lastKnownLiveSystemCodexEmail == "seeded@example.com")
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "seeded@example.com")
    }

    @Test
    func `dashboard refresh rejects stale completion during live account reconciliation lag`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard-reject-stale-live-lag")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-stale-live-lag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 12), provider: .codex)

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        #expect(expectedGuard.accountKey == nil)

        store._setSnapshotForTesting(self.codexSnapshot(email: "beta@example.com", usedPercent: 18), provider: .codex)

        await store.applyOpenAIDashboard(
            self.dashboard(email: "alpha@example.com", creditsRemaining: 40, usedPercent: 20),
            targetEmail: nil,
            expectedGuard: expectedGuard,
            allowCodexUsageBackfill: true)

        #expect(store.openAIDashboard == nil)
        #expect(store.credits == nil)
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "beta@example.com")
    }

    @Test
    func `default dashboard refresh path discards stale completion after account switch`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard-guard")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        self.installImmediateCodexProvider(
            on: store,
            snapshot: self.codexSnapshot(email: "alpha@example.com", usedPercent: 18))
        let dashboardBlocker = BlockingOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            try await dashboardBlocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let refreshTask = Task { await store.refresh() }
        await dashboardBlocker.waitUntilStarted()

        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")
        store._setSnapshotForTesting(self.codexSnapshot(email: "beta@example.com", usedPercent: 7), provider: .codex)
        store.openAIDashboard = nil
        store.credits = nil

        await dashboardBlocker.resume(with: .success(
            self.dashboard(email: "alpha@example.com", creditsRemaining: 44, usedPercent: 21)))
        await refreshTask.value

        #expect(store.openAIDashboard == nil)
        #expect(store.credits == nil)
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "beta@example.com")
    }

    @Test
    func `live switch invalidates stale codex state even when only last known live email remains`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-invalidate-with-stale-last-known")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-invalidate-stale-last-known-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 10), provider: .codex)
        store.credits = self.credits(remaining: 12)
        store.lastCreditsSnapshot = self.credits(remaining: 12)
        store.lastCreditsSnapshotAccountKey = "alpha@example.com"
        store.openAIDashboard = self.dashboard(email: "alpha@example.com", creditsRemaining: 12, usedPercent: 20)
        store.lastOpenAIDashboardSnapshot = store.openAIDashboard
        store.lastKnownLiveSystemCodexEmail = "alpha@example.com"
        store.lastCodexAccountScopedRefreshGuard = store.currentCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: false,
            allowLastKnownLiveFallback: true)

        settings._test_liveSystemCodexAccount = nil
        store.snapshots.removeValue(forKey: .codex)

        let didInvalidate = store.prepareCodexAccountScopedRefreshIfNeeded()
        await store.widgetSnapshotPersistTask?.value

        #expect(didInvalidate)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.credits == nil)
        #expect(store.openAIDashboard == nil)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == nil)
    }

    @Test
    func `codex account refresh persists widget snapshots on invalidation and completion`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-widgets")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 18), provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)

        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 77) }
        defer { store._test_codexCreditsLoaderOverride = nil }

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")
        let refreshTask = Task { await store.refreshCodexAccountScopedState(allowDisabled: true) }
        await blocker.waitUntilStarted()
        await blocker.resume(with: .success(self.codexSnapshot(email: "beta@example.com", usedPercent: 8)))
        await refreshTask.value
        await store.widgetSnapshotPersistTask?.value

        #expect(widgetSnapshots.count == 2)
        #expect(widgetSnapshots[0].entries.contains(where: { $0.provider == .codex }) == false)
        #expect(widgetSnapshots[1].entries.first { $0.provider == .codex }?.creditsRemaining == 77)
    }

    @Test
    func `widget snapshot saves stay ordered across codex account invalidation and completion`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-widget-order")
        settings.refreshFrequency = .manual

        let store = self.makeUsageStore(settings: settings)
        let saver = BlockingWidgetSnapshotSaver()
        store._test_widgetSnapshotSaveOverride = { snapshot in
            await saver.save(snapshot)
        }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "codex-account-invalidate")
        await saver.waitUntilStarted(count: 1)
        #expect(await saver.startedCount() == 1)

        store._setSnapshotForTesting(self.codexSnapshot(email: "beta@example.com", usedPercent: 8), provider: .codex)
        store.credits = self.credits(remaining: 77)
        store.persistWidgetSnapshot(reason: "codex-account-refresh")

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await saver.startedCount() == 1)

        await saver.resumeNext()
        await saver.waitUntilStarted(count: 2)
        await saver.resumeNext()
        await store.widgetSnapshotPersistTask?.value

        let snapshots = await saver.savedSnapshots()
        #expect(snapshots.count == 2)
        #expect(snapshots[0].entries.contains(where: { $0.provider == .codex }) == false)
        #expect(snapshots[1].entries.first { $0.provider == .codex }?.creditsRemaining == 77)
    }

    @Test
    func `codex account refresh reports usage and credits phases before completion`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-phases")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 18), provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)

        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 77) }
        defer { store._test_codexCreditsLoaderOverride = nil }

        var phases: [CodexAccountScopedRefreshPhase] = []
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")

        let refreshTask = Task {
            await store.refreshCodexAccountScopedState(
                allowDisabled: true,
                phaseDidChange: { phases.append($0) })
        }

        await blocker.waitUntilStarted()
        #expect(phases == [.invalidated])

        await blocker.resume(with: .success(self.codexSnapshot(email: "beta@example.com", usedPercent: 8)))
        await refreshTask.value

        #expect(phases == [.invalidated, .usage, .credits, .completed])
    }

    @Test
    func `refresh loads credits when codex email is discovered by usage in the same cycle`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-refresh-credits")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 55) }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let refreshTask = Task { await store.refresh() }
        await blocker.waitUntilStarted()
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 12)))
        await refreshTask.value

        #expect(store.credits?.remaining == 55)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "alpha@example.com")
    }

    @Test
    func `settings codex account selection refreshes credits on the first switch`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-settings-selection")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live@example.com")

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "live@example.com", usedPercent: 30), provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)
        self.installImmediateCodexProvider(
            on: store,
            snapshot: self.codexSnapshot(email: "managed@example.com", usedPercent: 9))
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 55) }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let pane = ProvidersPane(settings: settings, store: store)
        await pane._test_selectCodexVisibleAccount(id: "managed@example.com")

        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountID))
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "managed@example.com")
        #expect(store.credits?.remaining == 55)
    }

    private func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings._test_activeManagedCodexAccount = nil
        settings._test_activeManagedCodexRemoteHomePath = nil
        settings._test_unreadableManagedCodexAccountStore = false
        settings._test_managedCodexAccountStoreURL = nil
        settings._test_liveSystemCodexAccount = nil
        settings._test_codexReconciliationEnvironment = nil
        return settings
    }

    private func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private func liveAccount(email: String) -> ObservedSystemCodexAccount {
        ObservedSystemCodexAccount(
            email: email,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
    }

    private func codexSnapshot(email: String, usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    private func credits(remaining: Double) -> CreditsSnapshot {
        CreditsSnapshot(remaining: remaining, events: [], updatedAt: Date())
    }

    private func dashboard(email: String, creditsRemaining: Double, usedPercent: Double) -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: 88,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondaryLimit: nil,
            creditsRemaining: creditsRemaining,
            accountPlan: "Pro",
            updatedAt: Date())
    }

    private func makeManagedAccountStoreURL(accounts: [ManagedCodexAccount]) throws -> URL {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))
        return storeURL
    }

    private func installBlockingCodexProvider(on store: UsageStore, blocker: BlockingCodexFetchStrategy) {
        let baseSpec = store.providerSpecs[.codex]!
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) {
            try await blocker.awaitResult()
        }
    }

    private func installImmediateCodexProvider(on store: UsageStore, snapshot: UsageSnapshot) {
        let baseSpec = store.providerSpecs[.codex]!
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) {
            snapshot
        }
    }

    private static func makeCodexProviderSpec(
        baseSpec: ProviderSpec,
        loader: @escaping @Sendable () async throws -> UsageSnapshot) -> ProviderSpec
    {
        let baseDescriptor = baseSpec.descriptor
        let strategy = TestCodexFetchStrategy(loader: loader)
        let descriptor = ProviderDescriptor(
            id: .codex,
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
}

private struct TestRefreshError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

private struct TestCodexFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot

    var id: String {
        "test-codex"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.loader()
        return self.makeResult(usage: snapshot, sourceLabel: "test-codex")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private actor BlockingCodexFetchStrategy {
    private var waiters: [CheckedContinuation<Result<UsageSnapshot, Error>, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func awaitResult() async throws -> UsageSnapshot {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        let result = await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
        return try result.get()
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume(with result: Result<UsageSnapshot, Error>) {
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

private actor BlockingOpenAIDashboardLoader {
    private var waiters: [CheckedContinuation<Result<OpenAIDashboardSnapshot, Error>, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func awaitResult() async throws -> OpenAIDashboardSnapshot {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        let result = await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
        return try result.get()
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume(with result: Result<OpenAIDashboardSnapshot, Error>) {
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

private actor BlockingWidgetSnapshotSaver {
    private var snapshots: [WidgetSnapshot] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func save(_ snapshot: WidgetSnapshot) async {
        self.snapshots.append(snapshot)
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func waitUntilStarted(count: Int) async {
        if self.snapshots.count >= count { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func startedCount() -> Int {
        self.snapshots.count
    }

    func resumeNext() {
        guard !self.waiters.isEmpty else { return }
        let waiter = self.waiters.removeFirst()
        waiter.resume()
    }

    func savedSnapshots() -> [WidgetSnapshot] {
        self.snapshots
    }
}
