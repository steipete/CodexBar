import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexAccountReconciliationTests {
    @Test
    @MainActor
    func `settings store exposes codex reconciliation accessors using managed and live overrides`() throws {
        let suite = "CodexAccountReconciliationTests-settings-store"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managed
        settings._test_liveSystemCodexAccount = live
        settings.codexActiveSource = .managedAccount(id: managed.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(settings.codexActiveSource == .managedAccount(id: managed.id))
        #expect(snapshot.storedAccounts.map(\.id) == [managed.id])
        #expect(snapshot.storedAccounts.map(\.email) == [managed.email])
        #expect(snapshot.activeStoredAccount?.id == managed.id)
        #expect(snapshot.activeStoredAccount?.email == managed.email)
        #expect(snapshot.liveSystemAccount == live)
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(snapshot.activeSource == .managedAccount(id: managed.id))
        #expect(snapshot.hasUnreadableAddedAccountStore == false)
        #expect(Set(projection.visibleAccounts.map(\.email)) == ["managed@example.com", "system@example.com"])
        #expect(settings.codexVisibleAccounts == projection.visibleAccounts)
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
    }

    @Test
    @MainActor
    func `settings store managed override does not leak ambient live system account`() throws {
        let suite = "CodexAccountReconciliationTests-managed-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        settings._test_activeManagedCodexAccount = managed
        settings.codexActiveSource = .managedAccount(id: managed.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(settings.codexActiveSource == .managedAccount(id: managed.id))
        #expect(snapshot.liveSystemAccount == nil)
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(snapshot.activeSource == .managedAccount(id: managed.id))
        #expect(projection.visibleAccounts.map(\.email) == ["managed@example.com"])
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(projection.liveVisibleAccountID == nil)
    }

    @Test
    @MainActor
    func `settings store reconciliation environment override drives live observation with synthetic store`() throws {
        let suite = "CodexAccountReconciliationTests-environment-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try Self.writeCodexAuthFile(homeURL: ambientHome, email: "ambient@example.com", plan: "pro")
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": ambientHome.path]
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: ambientHome)
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(settings.codexActiveSource == .liveSystem)
        #expect(snapshot.storedAccounts.isEmpty)
        #expect(snapshot.activeStoredAccount == nil)
        #expect(snapshot.liveSystemAccount?.email == "ambient@example.com")
        #expect(snapshot.liveSystemAccount?.codexHomePath == ambientHome.path)
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(snapshot.activeSource == .liveSystem)
        #expect(projection.visibleAccounts.map(\.email) == ["ambient@example.com"])
        #expect(projection.activeVisibleAccountID == "ambient@example.com")
        #expect(projection.liveVisibleAccountID == "ambient@example.com")
    }

    @Test
    @MainActor
    func `settings store home path override also keeps reconciliation hermetic`() throws {
        let suite = "CodexAccountReconciliationTests-home-path-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings._test_activeManagedCodexRemoteHomePath = "/tmp/managed-route-home"
        settings._test_liveSystemCodexAccount = nil
        settings._test_codexReconciliationEnvironment = nil
        defer {
            settings._test_activeManagedCodexRemoteHomePath = nil
            settings._test_liveSystemCodexAccount = nil
            settings._test_codexReconciliationEnvironment = nil
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(snapshot.storedAccounts.isEmpty)
        #expect(snapshot.activeStoredAccount == nil)
        #expect(snapshot.liveSystemAccount == nil)
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(projection.visibleAccounts.isEmpty)
        #expect(projection.activeVisibleAccountID == nil)
        #expect(projection.liveVisibleAccountID == nil)
    }

    @Test
    @MainActor
    func `settings store home path override keeps active source hermetic without persisted source`() throws {
        let suite = "CodexAccountReconciliationTests-home-path-hermetic-source"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let ambient = ManagedCodexAccount(
            id: UUID(),
            email: "ambient-managed@example.com",
            managedHomePath: "/tmp/ambient-managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let accounts = ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [ambient])
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-store-\(UUID().uuidString).json")
        try Self.writeManagedCodexStore(accounts, to: storeURL)

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_activeManagedCodexRemoteHomePath = "/tmp/managed-route-home"
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_activeManagedCodexRemoteHomePath = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        let snapshot = settings.codexAccountReconciliationSnapshot

        #expect(settings.codexActiveSource == .liveSystem)
        #expect(settings.providerConfig(for: .codex)?.codexActiveSource == nil)
        #expect(snapshot.storedAccounts.map(\.id) == [ambient.id])
        #expect(snapshot.storedAccounts.map(\.email) == [ambient.email])
        #expect(snapshot.activeStoredAccount == nil)
        #expect(snapshot.activeSource == .liveSystem)
    }

    @Test
    @MainActor
    func `settings store normal reconciliation path honors persisted active source`() throws {
        let suite = "CodexAccountReconciliationTests-normal-path-active-source"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let persistedSource = CodexActiveSource.managedAccount(id: UUID())
        settings.codexActiveSource = persistedSource

        let snapshot = settings.codexAccountReconciliationSnapshot

        #expect(snapshot.activeSource == persistedSource)
    }

    @Test
    @MainActor
    func `settings store debug managed store U R L override loads on disk accounts`() throws {
        let suite = "CodexAccountReconciliationTests-debug-store-url"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "stored@example.com",
            managedHomePath: "/tmp/stored-managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let accounts = ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [stored])
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-store-\(UUID().uuidString).json")
        try Self.writeManagedCodexStore(accounts, to: storeURL)

        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: stored.id)
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        let snapshot = settings.codexAccountReconciliationSnapshot

        #expect(snapshot.storedAccounts.map(\.id) == [stored.id])
        #expect(snapshot.storedAccounts.map(\.email) == [stored.email])
        #expect(snapshot.activeStoredAccount?.id == stored.id)
        #expect(snapshot.activeStoredAccount?.email == stored.email)
        #expect(snapshot.activeSource == .managedAccount(id: stored.id))
    }

    @Test
    func `live only visible account is active when active source is live system`() {
        let live = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let projection = CodexVisibleAccountProjection.make(from: CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .liveSystem,
            hasUnreadableAddedAccountStore: false))

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com"])
        #expect(projection.activeVisibleAccountID == "live@example.com")
        #expect(projection.liveVisibleAccountID == "live@example.com")
    }

    @Test
    func `matching live system account does not duplicate stored identity`() {
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "user@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [stored])
        let live = ObservedSystemCodexAccount(
            email: "USER@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live),
            activeSource: .managedAccount(id: stored.id))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.count == 1)
        #expect(projection.activeVisibleAccountID == "user@example.com")
        #expect(projection.liveVisibleAccountID == "user@example.com")
    }

    @Test
    func `matching live system account resolves merged row selection to live system`() {
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "user@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "USER@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [stored],
            activeStoredAccount: stored,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: stored,
            activeSource: .managedAccount(id: stored.id),
            hasUnreadableAddedAccountStore: false)

        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)
        let projection = CodexVisibleAccountProjection.make(from: snapshot)

        #expect(resolution.persistedSource == .managedAccount(id: stored.id))
        #expect(resolution.resolvedSource == .liveSystem)
        #expect(resolution.requiresPersistenceCorrection)
        #expect(projection.activeVisibleAccountID == "user@example.com")
        #expect(projection.source(forVisibleAccountID: "user@example.com") == .liveSystem)
    }

    @Test
    func `missing managed source resolves to live system when live account exists`() {
        let live = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let missingID = UUID()
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: missingID),
            hasUnreadableAddedAccountStore: false)

        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)

        #expect(resolution.persistedSource == .managedAccount(id: missingID))
        #expect(resolution.resolvedSource == .liveSystem)
        #expect(resolution.requiresPersistenceCorrection)
    }

    @Test
    func `unreadable managed source resolves to live system when live account exists`() {
        let live = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let unreadableID = UUID()
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: unreadableID),
            hasUnreadableAddedAccountStore: true)

        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)

        #expect(resolution.persistedSource == .managedAccount(id: unreadableID))
        #expect(resolution.resolvedSource == .liveSystem)
        #expect(resolution.requiresPersistenceCorrection)
    }

    @Test
    func `managed account remains active when active source stays managed while live account changes`() {
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let projection = CodexVisibleAccountProjection.make(from: CodexAccountReconciliationSnapshot(
            storedAccounts: [managed],
            activeStoredAccount: managed,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: managed.id),
            hasUnreadableAddedAccountStore: false))

        #expect(Set(projection.visibleAccounts.map(\.email)) == [
            "managed@example.com",
            "system@example.com",
        ])
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
    }

    @Test
    func `live system account that differs from active stored account remains visible`() {
        let active = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [active])
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live),
            activeSource: .managedAccount(id: active.id))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(Set(projection.visibleAccounts.map(\.email)) == ["managed@example.com", "system@example.com"])
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
    }

    @Test
    func `inactive stored account still appears as visible`() {
        let active = ManagedCodexAccount(
            id: UUID(),
            email: "active@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let inactive = ManagedCodexAccount(
            id: UUID(),
            email: "inactive@example.com",
            managedHomePath: "/tmp/managed-b",
            createdAt: 4,
            updatedAt: 5,
            lastAuthenticatedAt: 6)
        let accounts = ManagedCodexAccountSet(
            version: 1,
            accounts: [active, inactive])
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live),
            activeSource: .managedAccount(id: active.id))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(Set(projection.visibleAccounts.map(\.email)) == [
            "active@example.com",
            "inactive@example.com",
            "system@example.com",
        ])
        #expect(projection.activeVisibleAccountID == "active@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
    }

    @Test
    func `unreadable account store still exposes live system account and degraded flag`() {
        let live = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { throw FileManagedCodexAccountStoreError.unsupportedVersion(999) },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com"])
        #expect(projection.activeVisibleAccountID == "live@example.com")
        #expect(projection.liveVisibleAccountID == "live@example.com")
        #expect(projection.hasUnreadableAddedAccountStore)
    }

    @Test
    func `whitespace only live email is ignored`() {
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [])
        let live = ObservedSystemCodexAccount(
            email: "   \n\t  ",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.isEmpty)
        #expect(projection.activeVisibleAccountID == nil)
        #expect(projection.liveVisibleAccountID == nil)
    }

    @Test
    @MainActor
    func `settings store can override active source to live system`() throws {
        let suite = "CodexAccountReconciliationTests-live-source-override"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managed
        settings._test_liveSystemCodexAccount = live
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(settings.codexActiveSource == .liveSystem)
        #expect(snapshot.activeSource == .liveSystem)
        #expect(projection.activeVisibleAccountID == "system@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
    }

    @Test
    @MainActor
    func `selecting merged visible account persists live system source`() throws {
        let suite = "CodexAccountReconciliationTests-select-merged-visible-account"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "same@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "SAME@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managed
        settings._test_liveSystemCodexAccount = live
        settings.codexActiveSource = .managedAccount(id: managed.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let didSelect = settings.selectCodexVisibleAccount(id: "same@example.com")

        #expect(didSelect)
        #expect(settings.codexActiveSource == .liveSystem)
        #expect(settings.codexResolvedActiveSource == .liveSystem)
    }

    @Test
    @MainActor
    func `selecting authenticated managed account prefers live system when visible row is merged`() throws {
        let suite = "CodexAccountReconciliationTests-select-authenticated-managed-merged"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "same@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "SAME@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managed
        settings._test_liveSystemCodexAccount = live
        settings.codexActiveSource = .managedAccount(id: UUID())
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        settings.selectAuthenticatedManagedCodexAccount(managed)

        #expect(settings.codexActiveSource == .liveSystem)
        #expect(settings.codexResolvedActiveSource == .liveSystem)
    }
}

private struct StubSystemObserver: CodexSystemAccountObserving {
    let account: ObservedSystemCodexAccount?

    func loadSystemAccount(environment _: [String: String]) throws -> ObservedSystemCodexAccount? {
        self.account
    }
}

extension CodexAccountReconciliationTests {
    private static func writeManagedCodexStore(_ accounts: ManagedCodexAccountSet, to storeURL: URL) throws {
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(accounts)
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": Self.fakeJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}
