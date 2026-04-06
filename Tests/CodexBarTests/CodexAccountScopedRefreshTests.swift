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
        store.lastCreditsSource = .api
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
        #expect(store.lastCreditsSource == .none)
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
    func `same email provider account switch discards stale codex usage success`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-stale-same-email-provider-account")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "alpha@example.com",
            identity: .providerAccount(id: "acct-alpha"))

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "alpha@example.com",
            identity: .providerAccount(id: "acct-beta"))
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
        #expect(store.lastCreditsSource == .none)
        #expect(store.lastCreditsError == "Codex credits are still loading; will retry shortly.")
    }

    @Test
    func `managed refresh invalidation keeps state when provider account is unchanged`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-managed-renamed-email")
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "renamed@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccountID = UUID()
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "legacy@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccountID)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = self.makeUsageStore(settings: settings)
        let currentSnapshot = self.codexSnapshot(email: "renamed@example.com", usedPercent: 10)
        let currentCredits = self.credits(remaining: 42)
        let currentDashboard = self.dashboard(email: "renamed@example.com", creditsRemaining: 42, usedPercent: 20)

        store._setSnapshotForTesting(currentSnapshot, provider: .codex)
        store.credits = currentCredits
        store.lastCreditsSnapshot = currentCredits
        store.lastCreditsSnapshotAccountKey = "renamed@example.com"
        store.openAIDashboard = currentDashboard
        store.lastOpenAIDashboardSnapshot = currentDashboard
        store.lastOpenAIDashboardTargetEmail = "renamed@example.com"
        store.seedCodexAccountScopedRefreshGuard(
            source: .managedAccount(id: managedAccountID),
            accountEmail: "renamed@example.com")

        let currentGuard = store.currentCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: false,
            allowLastKnownLiveFallback: false)
        let didInvalidate = store.prepareCodexAccountScopedRefreshIfNeeded()

        #expect(currentGuard.identity == .providerAccount(id: "acct-managed"))
        #expect(currentGuard.accountKey == "renamed@example.com")
        #expect(didInvalidate == false)
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "renamed@example.com")
        #expect(store.credits?.remaining == 42)
        #expect(store.openAIDashboard?.signedInEmail == "renamed@example.com")
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
        #expect(elapsed < .seconds(3))
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
    func `dashboard refresh fail closes when live identity is unresolved without trusted continuity`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard-unresolved-fail-closed")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-unresolved-fail-closed-\(UUID().uuidString)", isDirectory: true)
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
        #expect(expectedGuard.identity == .unresolved)
        #expect(expectedGuard.accountKey == nil)

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardSnapshot == nil)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.credits == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("could not be verified") == true)
    }

    @Test
    func `dashboard refresh attaches for unresolved live identity with trusted non dashboard continuity`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-dashboard-unresolved-trusted-continuity")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-unresolved-trusted-\(UUID().uuidString)", isDirectory: true)
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
        store._setSnapshotForTesting(
            self.codexSnapshot(email: "trusted@example.com", usedPercent: 12),
            provider: .codex)
        store.lastSourceLabels[.codex] = "codex-cli"
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            self.dashboard(email: "trusted@example.com", creditsRemaining: 33, usedPercent: 12)
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        #expect(expectedGuard.identity == .unresolved)

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(store.openAIDashboard?.signedInEmail == "trusted@example.com")
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "trusted@example.com")
        #expect(store.lastSourceLabels[.codex] == "codex-cli")
        #expect(store.credits?.remaining == 33)
        #expect(store.lastCreditsSource == .dashboardWeb)
        #expect(store.lastCreditsSnapshotAccountKey == "trusted@example.com")
        #expect(
            store.lastCodexAccountScopedRefreshGuard?.identity ==
                .emailOnly(normalizedEmail: "trusted@example.com"))
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "trusted@example.com")
    }

    @Test
    func `no usable codex usage does not block weekly only dashboard backfill`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-no-usable-usage-weekly-dashboard-backfill")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "weekly@example.com",
            identity: .providerAccount(id: "acct-weekly"))

        let store = self.makeUsageStore(settings: settings)
        self.installFailingCodexProvider(on: store, error: UsageError.noRateLimitsFound)

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex] == nil)

        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: "weekly@example.com",
                codeReviewRemainingPercent: 88,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                primaryLimit: nil,
                secondaryLimit: RateWindow(
                    usedPercent: 27,
                    windowMinutes: 10080,
                    resetsAt: Date(timeIntervalSince1970: 1_775_000_000),
                    resetDescription: "next week"),
                creditsRemaining: 14,
                accountPlan: "Pro",
                updatedAt: Date(timeIntervalSince1970: 1_774_900_000)),
            targetEmail: "weekly@example.com",
            allowCodexUsageBackfill: true)

        #expect(store.openAIDashboard?.signedInEmail == "weekly@example.com")
        #expect(store.snapshots[.codex]?.primary == nil)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 27)
        #expect(store.snapshots[.codex]?.secondary?.windowMinutes == 10080)
        #expect(store.lastSourceLabels[.codex] == "openai-web")
    }

    @Test
    func `dashboard display only keeps dashboard visible and clears dashboard derived data`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard-display-only-cleanup")
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "shared@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: managedStoreURL)
            OpenAIDashboardCacheStore.clear()
        }

        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "shared@example.com",
            identity: .emailOnly(normalizedEmail: "shared@example.com"))
        settings.codexActiveSource = .liveSystem

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "shared@example.com", usedPercent: 20), provider: .codex)
        store.lastSourceLabels[.codex] = "openai-web"
        let staleCredits = self.credits(remaining: 20)
        store.credits = staleCredits
        store.lastCreditsSnapshot = staleCredits
        store.lastCreditsSnapshotAccountKey = "shared@example.com"
        store.lastCreditsSource = .dashboardWeb
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "shared@example.com",
            snapshot: self.dashboard(email: "shared@example.com", creditsRemaining: 20, usedPercent: 20)))

        await store.applyOpenAIDashboard(
            self.dashboard(email: "shared@example.com", creditsRemaining: 9, usedPercent: 35),
            targetEmail: "shared@example.com")

        #expect(store.openAIDashboard?.signedInEmail == "shared@example.com")
        #expect(store.lastOpenAIDashboardSnapshot?.signedInEmail == "shared@example.com")
        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == nil)
        #expect(store.credits == nil)
        #expect(store.lastCreditsSource == .none)
        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    @Test
    func `dashboard downgrade from real attach to display only retires owned state immediately`() async throws {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard-downgrade")
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "shared@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: managedStoreURL)
        }

        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "shared@example.com",
            identity: .emailOnly(normalizedEmail: "shared@example.com"))
        settings.codexActiveSource = .liveSystem

        let store = self.makeUsageStore(settings: settings)
        await store.applyOpenAIDashboard(
            self.dashboard(email: "shared@example.com", creditsRemaining: 20, usedPercent: 20),
            targetEmail: "shared@example.com")

        #expect(store.openAIDashboard?.signedInEmail == "shared@example.com")
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "shared@example.com")
        #expect(store.lastSourceLabels[.codex] == "openai-web")
        #expect(store.credits?.remaining == 20)
        #expect(store.lastCreditsSource == .dashboardWeb)
        #expect(OpenAIDashboardCacheStore.load()?.accountEmail == "shared@example.com")

        settings._test_managedCodexAccountStoreURL = managedStoreURL

        await store.applyOpenAIDashboard(
            self.dashboard(email: "shared@example.com", creditsRemaining: 9, usedPercent: 35),
            targetEmail: "shared@example.com")

        #expect(store.openAIDashboard?.signedInEmail == "shared@example.com")
        #expect(store.lastOpenAIDashboardSnapshot?.signedInEmail == "shared@example.com")
        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == nil)
        #expect(store.credits == nil)
        #expect(store.lastCreditsSource == .none)
        #expect(OpenAIDashboardCacheStore.load() == nil)
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
    func `same email provider account switch discards stale dashboard completion`() async {
        let settings = self
            .makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard-same-email-provider-account")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "alpha@example.com",
            identity: .providerAccount(id: "acct-alpha"))

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        #expect(expectedGuard.identity == .providerAccount(id: "acct-alpha"))

        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "alpha@example.com",
            identity: .providerAccount(id: "acct-beta"))

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
    func `widget snapshot excludes display only dashboard code review`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-widget-display-only-dashboard")
        settings.refreshFrequency = .manual

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 18), provider: .codex)
        store.credits = CreditsSnapshot(remaining: 12, events: [], updatedAt: Date())
        store.openAIDashboard = self.dashboard(
            email: "alpha@example.com",
            creditsRemaining: 12,
            usedPercent: 20)
        store.openAIDashboardAttachmentAuthorized = false

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "display-only-dashboard")
        await store.widgetSnapshotPersistTask?.value

        let codexEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .codex })
        #expect(codexEntry.creditsRemaining == nil)
        #expect(codexEntry.codeReviewRemainingPercent == nil)
    }

    @Test
    func `widget snapshot includes attached dashboard code review`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-widget-attached-dashboard")
        settings.refreshFrequency = .manual

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 18), provider: .codex)
        store.openAIDashboard = self.dashboard(
            email: "alpha@example.com",
            creditsRemaining: 12,
            usedPercent: 20)
        store.openAIDashboardAttachmentAuthorized = true

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "attached-dashboard")
        await store.widgetSnapshotPersistTask?.value

        let codexEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .codex })
        #expect(codexEntry.codeReviewRemainingPercent == 88)
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
        #expect(store.lastCreditsSource == .api)
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
}
