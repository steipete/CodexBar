import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexAccountFingerprintReconciliationTests {
    @Test
    func `active source falls back to identity when auth fingerprint rotated`() throws {
        let accountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-333333333333"))
        let managed = ManagedCodexAccount(
            id: accountID,
            email: "rotated@example.com",
            authFingerprint: "old-auth-json",
            managedHomePath: "/tmp/rotated",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "rotated@example.com",
            authFingerprint: "new-auth-json",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "rotated@example.com"))
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [managed],
            activeStoredAccount: managed,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: managed,
            activeSource: .managedAccount(id: accountID),
            hasUnreadableAddedAccountStore: false)

        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)

        #expect(resolution.resolvedSource == .liveSystem)
        #expect(resolution.requiresPersistenceCorrection)
    }

    @Test
    @MainActor
    func `auth fingerprint does not collapse explicit managed workspace into unresolved live owner`() throws {
        let suite = "CodexAccountFingerprintReconciliationTests-auth-fingerprint"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let firstID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let secondID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let first = ManagedCodexAccount(
            id: firstID,
            email: "same@example.com",
            authFingerprint: "1111",
            managedHomePath: "/tmp/first",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let second = ManagedCodexAccount(
            id: secondID,
            email: "same@example.com",
            providerAccountID: "account-team",
            authFingerprint: "2222",
            managedHomePath: "/tmp/second",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-store-\(UUID().uuidString).json")
        try Self.writeManagedCodexStore(
            ManagedCodexAccountSet(version: FileManagedCodexAccountStore.currentVersion, accounts: [first, second]),
            to: storeURL)
        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "same@example.com",
            authFingerprint: "2222",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "same@example.com"))
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(snapshot.matchingStoredAccountForLiveSystemAccount?.id == firstID)
        #expect(projection.liveVisibleAccountID == "live:email:same@example.com")
        #expect(projection.visibleAccounts.first { $0.storedAccountID == secondID }?.isLive == false)
        #expect(projection.visibleAccounts.first { $0.storedAccountID == firstID }?.isLive == true)
    }

    @Test
    func `legacy fingerprint merges missing managed home with live provider account`() throws {
        let accountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-444444444444"))
        let missingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-managed-codex-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: missingHome)
        let legacy = ManagedCodexAccount(
            id: accountID,
            email: "same@example.com",
            authFingerprint: "shared-fingerprint",
            managedHomePath: missingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "same@example.com",
            workspaceAccountID: "account-live",
            authFingerprint: "shared-fingerprint",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { ManagedCodexAccountSet(version: 1, accounts: [legacy]) },
            systemObserver: FingerprintSystemObserver(account: live),
            activeSource: .managedAccount(id: accountID),
            baseEnvironment: [:])

        let snapshot = reconciler.loadSnapshot()
        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)
        let projection = CodexVisibleAccountProjection.make(from: snapshot)

        #expect(snapshot.storedAccountRuntimeIdentities[accountID] ==
            .emailOnly(normalizedEmail: "same@example.com"))
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount?.id == accountID)
        #expect(resolution.resolvedSource == .liveSystem)
        #expect(resolution.requiresPersistenceCorrection)
        #expect(projection.visibleAccounts.count == 1)
        #expect(projection.visibleAccounts.first?.storedAccountID == accountID)
        #expect(projection.visibleAccounts.first?.selectionSource == .liveSystem)
        #expect(projection.visibleAccounts.first?.isLive == true)
        #expect(projection.activeVisibleAccountID == projection.liveVisibleAccountID)
    }

    @Test
    func `selected workspace fingerprint merges missing managed home with matching live owner`() throws {
        let accountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-555555555555"))
        let missingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-selected-codex-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: missingHome)
        let selected = ManagedCodexAccount(
            id: accountID,
            email: "same@example.com",
            workspaceAccountID: "account-live",
            authFingerprint: "shared-fingerprint",
            managedHomePath: missingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "same@example.com",
            workspaceAccountID: "account-live",
            authFingerprint: "shared-fingerprint",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { ManagedCodexAccountSet(version: 1, accounts: [selected]) },
            systemObserver: FingerprintSystemObserver(account: live),
            activeSource: .managedAccount(id: accountID),
            baseEnvironment: [:])

        let snapshot = reconciler.loadSnapshot()
        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)
        let projection = CodexVisibleAccountProjection.make(from: snapshot)

        #expect(snapshot.storedAccountRuntimeIdentities[accountID] ==
            .emailOnly(normalizedEmail: "same@example.com"))
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount?.id == accountID)
        #expect(resolution.resolvedSource == .liveSystem)
        #expect(resolution.requiresPersistenceCorrection)
        #expect(projection.visibleAccounts.count == 1)
        #expect(projection.visibleAccounts.first?.storedAccountID == accountID)
        #expect(projection.visibleAccounts.first?.selectionSource == .liveSystem)
        #expect(projection.visibleAccounts.first?.isLive == true)
        #expect(projection.activeVisibleAccountID == projection.liveVisibleAccountID)
    }

    @Test
    func `selected workspace outranks legacy fingerprint match for the same live owner`() throws {
        let legacyID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-666666666666"))
        let selectedID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-777777777777"))
        let legacy = ManagedCodexAccount(
            id: legacyID,
            email: "same@example.com",
            authFingerprint: "shared-fingerprint",
            managedHomePath: "/tmp/legacy",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let selected = ManagedCodexAccount(
            id: selectedID,
            email: "same@example.com",
            workspaceAccountID: "account-live",
            authFingerprint: "shared-fingerprint",
            managedHomePath: "/tmp/selected",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "same@example.com",
            workspaceAccountID: "account-live",
            authFingerprint: "shared-fingerprint",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "account-live"))
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { ManagedCodexAccountSet(version: 1, accounts: [legacy, selected]) },
            systemObserver: FingerprintSystemObserver(account: live),
            activeSource: .managedAccount(id: selectedID),
            baseEnvironment: [:])

        let snapshot = reconciler.loadSnapshot()
        let projection = CodexVisibleAccountProjection.make(from: snapshot)

        #expect(snapshot.matchingStoredAccountForLiveSystemAccount?.id == selectedID)
        #expect(projection.visibleAccounts.first { $0.storedAccountID == selectedID }?.isLive == true)
        #expect(projection.visibleAccounts.first { $0.storedAccountID == legacyID }?.isLive == false)
    }

    private static func writeManagedCodexStore(_ accounts: ManagedCodexAccountSet, to storeURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(accounts)
        try data.write(to: storeURL, options: [.atomic])
    }
}

private struct FingerprintSystemObserver: CodexSystemAccountObserving {
    let account: ObservedSystemCodexAccount?

    func loadSystemAccount(environment _: [String: String]) throws -> ObservedSystemCodexAccount? {
        self.account
    }
}
