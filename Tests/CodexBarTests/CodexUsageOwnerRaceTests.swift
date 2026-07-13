import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `credits completion retires usage from another workspace member`() async {
        let suite = "CodexUsageOwnerRaceTests-credits-first"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "member-a@example.com",
            identity: .providerAccount(id: "shared-workspace"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let prior = self.codexWeeklySnapshot(
            email: "member-a@example.com",
            weeklyUsedPercent: 72,
            weeklyReset: now.addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: now.addingTimeInterval(-60))
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)

        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "member-b@example.com",
            identity: .providerAccount(id: "shared-workspace"))
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 23) }
        defer { store._test_codexCreditsLoaderOverride = nil }

        await store.refreshCreditsIfNeeded()

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.lastCodexUsagePublicationGuard == nil)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "member-b@example.com")
        #expect(store.credits?.remaining == 23)

        let nextReset = now.addingTimeInterval(9 * 24 * 60 * 60)
        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(self.codexWeeklySnapshot(
                email: "member-b@example.com",
                weeklyUsedPercent: 0.2,
                weeklyReset: nextReset,
                updatedAt: now.addingTimeInterval(-30))),
            .failure("confirmation unavailable"),
        ])
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.credits?.remaining == 23)
    }

    @Test
    func `dashboard cleanup retires cli usage from another workspace member`() async {
        let suite = "CodexUsageOwnerRaceTests-dashboard-cleanup"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "member-a@example.com",
            identity: .providerAccount(id: "shared-workspace"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let prior = self.codexWeeklySnapshot(
            email: "member-a@example.com",
            weeklyUsedPercent: 72,
            weeklyReset: Date().addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: Date().addingTimeInterval(-60))
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)

        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "member-b@example.com",
            identity: .providerAccount(id: "shared-workspace"))
        await store.applyOpenAIDashboard(
            self.dashboard(email: "member-a@example.com", creditsRemaining: 8, usedPercent: 40),
            targetEmail: "member-b@example.com")

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.lastCodexUsagePublicationGuard == nil)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "member-b@example.com")
    }

    @Test
    func `stale usage rejection preserves newer owner credits`() async {
        let suite = "CodexUsageOwnerRaceTests-stale-usage-new-credits"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-a@example.com",
            identity: .providerAccount(id: "owner-a"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let prior = self.codexWeeklySnapshot(
            email: "owner-a@example.com",
            weeklyUsedPercent: 61,
            weeklyReset: Date().addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: Date().addingTimeInterval(-60))
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-b@example.com",
            identity: .providerAccount(id: "owner-b"))
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 31) }
        defer { store._test_codexCreditsLoaderOverride = nil }
        await store.refreshCreditsIfNeeded()
        #expect(store.credits?.remaining == 31)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "owner-b@example.com")

        await blocker.resume(with: .success(self.codexSnapshot(email: "owner-a@example.com", usedPercent: 62)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.credits?.remaining == 31)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "owner-b@example.com")
    }

    @Test
    func `stacked stale selection preserves newer selected account credits`() async throws {
        let suite = "CodexUsageOwnerRaceTests-stacked-stale-selection"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "stacked-a@example.com",
            identity: .providerAccount(id: "stacked-owner-a"))
        let managedID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-515151515151"))
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-stacked-owner-race-\(UUID().uuidString)", isDirectory: true)
        let managedAccount = try self.makeManagedCodexWeeklyPublicationAccount(
            id: managedID,
            email: "stacked-b@example.com",
            workspaceID: "stacked-owner-b",
            workspaceLabel: "Team B",
            homeURL: managedHome)
        let accountStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_liveSystemCodexAccount = nil
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: accountStoreURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = accountStoreURL
        settings.codexActiveSource = .liveSystem

        let now = Date()
        let prior = self.codexWeeklySnapshot(
            email: "stacked-a@example.com",
            weeklyUsedPercent: 61,
            weeklyReset: now.addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: now.addingTimeInterval(-60))
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        let blocker = BlockingCodexFetchStrategy()
        let managedHomePath = managedHome.path
        let managedSnapshot = self.codexSnapshot(email: "stacked-b@example.com", usedPercent: 33)
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == managedHomePath {
                return managedSnapshot
            }
            return try await blocker.awaitResult()
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        settings.codexActiveSource = .managedAccount(id: managedID)
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 37) }
        defer { store._test_codexCreditsLoaderOverride = nil }
        await store.refreshCreditsIfNeeded()
        #expect(store.credits?.remaining == 37)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "stacked-b@example.com")

        await blocker.resume(with: .success(self.codexSnapshot(email: "stacked-a@example.com", usedPercent: 62)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.credits?.remaining == 37)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "stacked-b@example.com")
    }

    @Test
    func `in flight success retires prior usage after owner switch`() async {
        let suite = "CodexUsageOwnerRaceTests-in-flight-success"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-a@example.com",
            identity: .providerAccount(id: "owner-a"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let prior = self.codexWeeklySnapshot(
            email: "owner-a@example.com",
            weeklyUsedPercent: 61,
            weeklyReset: Date().addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: Date().addingTimeInterval(-60))
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-b@example.com",
            identity: .providerAccount(id: "owner-b"))
        await blocker.resume(with: .success(self.codexSnapshot(email: "owner-a@example.com", usedPercent: 62)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.lastCodexUsagePublicationGuard == nil)
    }

    @Test
    func `in flight failure retires prior usage after owner switch`() async {
        let suite = "CodexUsageOwnerRaceTests-in-flight-failure"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-a@example.com",
            identity: .providerAccount(id: "owner-a"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let prior = self.codexWeeklySnapshot(
            email: "owner-a@example.com",
            weeklyUsedPercent: 61,
            weeklyReset: Date().addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: Date().addingTimeInterval(-60))
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-b@example.com",
            identity: .providerAccount(id: "owner-b"))
        await blocker.resume(with: .failure(TestRefreshError(message: "old owner failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.lastCodexUsagePublicationGuard == nil)
    }

    @Test
    func `in flight confirmation retires prior usage after owner switch`() async {
        let suite = "CodexUsageOwnerRaceTests-in-flight-confirmation"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-a@example.com",
            identity: .providerAccount(id: "owner-a"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let priorReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        let nextReset = priorReset.addingTimeInterval(7 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: "owner-a@example.com",
            weeklyUsedPercent: 61,
            weeklyReset: priorReset,
            updatedAt: now.addingTimeInterval(-60))
        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(self.codexWeeklySnapshot(
                email: "owner-a@example.com",
                weeklyUsedPercent: 0.2,
                weeklyReset: nextReset,
                updatedAt: now.addingTimeInterval(-40))),
            .success(self.codexWeeklySnapshot(
                email: "owner-a@example.com",
                weeklyUsedPercent: 60,
                weeklyReset: priorReset,
                updatedAt: now.addingTimeInterval(-20)), gated: true),
        ])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        #expect(await loader.waitUntilCallCount(2))
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-b@example.com",
            identity: .providerAccount(id: "owner-b"))
        await loader.release(call: 2)
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.lastCodexUsagePublicationGuard == nil)
    }

    @Test
    func `unresolved live publication remains stable across the next failed refresh`() async throws {
        let suite = "CodexUsageOwnerRaceTests-unresolved-continuity"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings.codexActiveSource = .liveSystem
        settings._test_liveSystemCodexAccount = nil

        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        self.installImmediateCodexProvider(
            on: store,
            snapshot: self.codexSnapshot(email: "discovered@example.com", usedPercent: 27))

        await store.refreshProvider(.codex, allowDisabled: true)

        let publishedAt = try #require(store.snapshots[.codex]?.updatedAt)
        #expect(store.lastCodexUsagePublicationGuard?.identity == .emailOnly(
            normalizedEmail: "discovered@example.com"))
        self.installFailingCodexProvider(
            on: store,
            error: TestRefreshError(message: "temporary failure"))

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.updatedAt == publishedAt)
        #expect(store.lastCodexUsagePublicationGuard?.accountKey == "discovered@example.com")
    }

    @Test
    func `fresh failure is retired before attaching credits to another owner`() async {
        let suite = "CodexUsageOwnerRaceTests-fresh-failure-then-credits"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-a@example.com",
            identity: .providerAccount(id: "owner-a"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        self.installFailingCodexProvider(
            on: store,
            error: TestRefreshError(message: "owner A unavailable"))

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == "owner A unavailable")
        #expect(store.lastFetchAttempts[.codex]?.isEmpty == false)
        #expect(store.lastCodexUsagePublicationGuard?.accountKey == "owner-a@example.com")

        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-b@example.com",
            identity: .providerAccount(id: "owner-b"))
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 29) }
        defer { store._test_codexCreditsLoaderOverride = nil }

        await store.refreshCreditsIfNeeded()

        #expect(store.errors[.codex] == nil)
        #expect(store.lastFetchAttempts[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == nil)
        #expect(store.credits?.remaining == 29)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "owner-b@example.com")
    }

    @Test
    func `stacked fresh failure follows its owner across credits attachment`() async {
        let suite = "CodexUsageOwnerRaceTests-stacked-failure-then-credits"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-a@example.com",
            identity: .providerAccount(id: "owner-a"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let ownerA = CodexVisibleAccount(
            id: "live:owner-a",
            email: "owner-a@example.com",
            workspaceAccountID: "owner-a",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let failure = ProviderFetchOutcome(
            result: .failure(TestRefreshError(message: "owner A unavailable")),
            attempts: [ProviderFetchAttempt(
                strategyID: "stacked-test",
                kind: .cli,
                wasAvailable: true,
                errorDescription: "owner A unavailable")])

        await store.applySelectedCodexVisibleAccountOutcome(
            failure,
            account: ownerA,
            snapshot: nil,
            sourceLabel: nil,
            limitResetOwnerKey: nil)

        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 19) }
        defer { store._test_codexCreditsLoaderOverride = nil }
        await store.refreshCreditsIfNeeded()

        #expect(store.errors[.codex] == "owner A unavailable")
        #expect(store.lastFetchAttempts[.codex]?.first?.strategyID == "stacked-test")
        #expect(store.credits?.remaining == 19)

        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "owner-b@example.com",
            identity: .providerAccount(id: "owner-b"))
        await store.refreshCreditsIfNeeded()

        #expect(store.errors[.codex] == nil)
        #expect(store.lastFetchAttempts[.codex] == nil)
        #expect(store.credits?.remaining == 19)
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "owner-b@example.com")
    }
}
