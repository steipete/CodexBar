import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(CodexCredentialFixtures())
struct CodexReauthenticationRoutingTests {
    enum Kind: Sendable, Equatable {
        case merged, managed, live
    }

    @Test(arguments: [Kind.merged, .managed, .live])
    func `reauthentication follows the visible credential owner`(_ kind: Kind) async throws {
        let fixture = try self.fixture(kind: kind)
        defer { fixture.store.stopSharedSpendDashboardPublication() }
        let row = try #require(fixture.pane._test_codexAccountsSectionState()?.visibleAccounts.first)
        if kind == .merged {
            #expect(row.storedAccountID != nil)
            #expect(row.selectionSource == .liveSystem)
        }

        await fixture.pane._test_reauthenticateCodexAccount(row)

        #expect(await fixture.runner.calls == [kind == .managed ? "managed" : "system"])
        #expect(fixture.refreshes.value == (kind == .managed ? 0 : 1))
        #expect(try fixture.managedStore.loadAccounts().accounts.map(\.managedHomePath) ==
            fixture.snapshot.value.storedAccounts.map(\.managedHomePath))
    }

    @Test
    func `queued reauthentication rejects a row whose credential owner changed`() async throws {
        let fixture = try self.fixture(kind: .merged)
        defer { fixture.store.stopSharedSpendDashboardPublication() }
        let row = try #require(fixture.pane._test_codexAccountsSectionState()?.visibleAccounts.first)
        let stored = try #require(fixture.snapshot.value.storedAccounts.first)
        fixture.snapshot.setValue(Self.snapshot(
            stored: stored,
            live: nil,
            activeSource: .managedAccount(id: stored.id)))
        fixture.settings.invalidateCodexAccountReconciliationSnapshotCache()
        let current = try #require(fixture.pane._test_codexAccountsSectionState()?.visibleAccounts.first)
        #expect(current.id == row.id)
        #expect(current.selectionSource != row.selectionSource)

        await fixture.pane._test_reauthenticateCodexAccount(row)

        #expect(await fixture.runner.calls.isEmpty)
        #expect(fixture.refreshes.value == 0)
    }

    @Test
    func `queued reauthentication rejects a removed row`() async throws {
        let fixture = try self.fixture(kind: .merged)
        defer { fixture.store.stopSharedSpendDashboardPublication() }
        let row = try #require(fixture.pane._test_codexAccountsSectionState()?.visibleAccounts.first)
        fixture.snapshot.setValue(Self.snapshot(stored: nil, live: nil, activeSource: .liveSystem))
        fixture.settings.invalidateCodexAccountReconciliationSnapshotCache()

        await fixture.pane._test_reauthenticateCodexAccount(row)

        #expect(await fixture.runner.calls.isEmpty)
        #expect(fixture.refreshes.value == 0)
    }

    @Test
    func `queued system reauthentication rejects a different workspace with the same row id`() async throws {
        let fixture = try self.fixture(kind: .live)
        defer { fixture.store.stopSharedSpendDashboardPublication() }
        let row = try #require(fixture.pane._test_codexAccountsSectionState()?.visibleAccounts.first)
        let live = ObservedSystemCodexAccount(
            email: row.email,
            workspaceAccountID: "workspace-other",
            codexHomePath: CodexCredentialFixtures.root.appendingPathComponent("system").path,
            observedAt: Date(),
            identity: .providerAccount(id: "workspace-other"))
        fixture.snapshot.setValue(Self.snapshot(stored: nil, live: live, activeSource: .liveSystem))
        fixture.settings.invalidateCodexAccountReconciliationSnapshotCache()
        let current = try #require(fixture.pane._test_codexAccountsSectionState()?.visibleAccounts.first)
        #expect(current.id == row.id)
        #expect(current.selectionSource == row.selectionSource)
        #expect(current.workspaceAccountID != row.workspaceAccountID)

        await fixture.pane._test_reauthenticateCodexAccount(row)

        #expect(await fixture.runner.calls.isEmpty)
        #expect(fixture.refreshes.value == 0)
    }

    @Test
    func `merged system row uses live progress and does not require the managed store`() throws {
        let fixture = try self.fixture(kind: .merged)
        defer { fixture.store.stopSharedSpendDashboardPublication() }
        let row = try #require(fixture.pane._test_codexAccountsSectionState()?.visibleAccounts.first)
        func state(unreadable: Bool, authenticatingLive: Bool) -> CodexAccountsSectionState {
            CodexAccountsSectionState(
                visibleAccounts: [row],
                activeVisibleAccountID: row.id,
                liveVisibleAccountID: row.id,
                hasUnreadableManagedAccountStore: unreadable,
                isAuthenticatingManagedAccount: false,
                authenticatingManagedAccountID: nil,
                isRemovingManagedAccount: false,
                isAuthenticatingLiveAccount: authenticatingLive,
                isPromotingSystemAccount: false,
                notice: nil)
        }
        #expect(state(unreadable: false, authenticatingLive: true).reauthenticateTitle(for: row) ==
            "Re-authenticating…")
        #expect(!state(unreadable: false, authenticatingLive: true).canReauthenticate(row))
        #expect(state(unreadable: true, authenticatingLive: false).canReauthenticate(row))
    }

    private func fixture(kind: Kind) throws -> Fixture {
        let root = CodexCredentialFixtures.root
        let environment = ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("system").path]
        let config = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        let settings = ProviderUsageItemVisibilityTests.settings(
            defaults: InMemoryUserDefaults(values: ["codexbar.legacySecretsMigrationCompleted": true]),
            configStore: config)
        settings._test_codexReconciliationEnvironment = environment
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.costUsageEnabled = false
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let stored = kind == .live ? nil : ManagedCodexAccount(
            id: UUID(),
            email: "account@example.com",
            providerAccountID: "workspace-example",
            managedHomePath: root.appendingPathComponent("managed/original").path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let live = kind == .managed ? nil : ObservedSystemCodexAccount(
            email: "account@example.com",
            codexHomePath: environment["CODEX_HOME"]!,
            observedAt: Date(),
            identity: .providerAccount(id: "workspace-example"))
        let activeSource: CodexActiveSource = kind == .managed ? .managedAccount(id: stored!.id) : .liveSystem
        let snapshot = LockIsolated(Self.snapshot(stored: stored, live: live, activeSource: activeSource))
        settings._test_codexAccountSnapshotLoader = { _ in snapshot.value }
        settings.codexActiveSource = activeSource
        let managedStore = FileManagedCodexAccountStore(fileURL: root.appendingPathComponent("accounts.json"))
        try managedStore.storeAccounts(.init(
            version: FileManagedCodexAccountStore.currentVersion, accounts: stored.map { [$0] } ?? []))
        let runner = ReauthenticationRecordingRunner()
        let coordinator = ManagedCodexAccountCoordinator(service: ManagedCodexAccountService(
            store: managedStore,
            homeFactory: ManagedCodexHomeFactory(root: root.appendingPathComponent("managed")),
            loginRunner: runner,
            identityReader: UnusedReauthenticationIdentityReader()))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let refreshes = LockIsolated(0)
        store._test_providerRefreshOverride = { _ in refreshes.setValue(refreshes.value + 1) }
        store._test_codexCreditsLoaderOverride = { throw UsageError.noRateLimitsFound }
        store._test_widgetSnapshotSaveOverride = { _ in }
        let pane = ProvidersPane(
            settings: settings,
            store: store,
            managedCodexAccountCoordinator: coordinator,
            codexAmbientLoginRunner: runner)
        return Fixture(
            settings: settings,
            store: store,
            pane: pane,
            runner: runner,
            snapshot: snapshot,
            managedStore: managedStore,
            refreshes: refreshes)
    }

    private static func snapshot(
        stored: ManagedCodexAccount?, live: ObservedSystemCodexAccount?, activeSource: CodexActiveSource)
        -> CodexAccountReconciliationSnapshot
    {
        CodexAccountReconciliationSnapshot(
            storedAccounts: stored.map { [$0] } ?? [],
            activeStoredAccount: stored,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: live == nil ? nil : stored,
            activeSource: activeSource,
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: stored.map { [$0.id: .providerAccount(id: "workspace-example")] } ?? [:])
    }

    private struct Fixture {
        let settings: SettingsStore
        let store: UsageStore
        let pane: ProvidersPane
        let runner: ReauthenticationRecordingRunner
        let snapshot: LockIsolated<CodexAccountReconciliationSnapshot>
        let managedStore: FileManagedCodexAccountStore
        let refreshes: LockIsolated<Int>
    }
}

private actor ReauthenticationRecordingRunner: CodexAmbientLoginRunning, ManagedCodexLoginRunning {
    private(set) var calls: [String] = []

    func run(timeout _: TimeInterval) async -> CLILoginRunner.Result {
        self.calls.append("system")
        return .init(outcome: .success, output: "synthetic system login")
    }

    func run(homePath _: String, timeout _: TimeInterval) async -> CLILoginRunner.Result {
        self.calls.append("managed")
        return .init(outcome: .cancelled, output: "synthetic managed login cancelled")
    }
}

private struct UnusedReauthenticationIdentityReader: ManagedCodexIdentityReading {
    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        throw ManagedCodexAccountServiceError.missingEmail
    }
}
