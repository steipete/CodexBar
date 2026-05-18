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
    func `auth fingerprint matches live account before semantic duplicate identity`() throws {
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

        #expect(snapshot.matchingStoredAccountForLiveSystemAccount?.id == secondID)
        #expect(projection.liveVisibleAccountID == "live:email:same@example.com")
        #expect(projection.visibleAccounts.first { $0.storedAccountID == secondID }?.isLive == true)
        #expect(projection.visibleAccounts.first { $0.storedAccountID == firstID }?.isLive == false)
    }

    private static func writeManagedCodexStore(_ accounts: ManagedCodexAccountSet, to storeURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(accounts)
        try data.write(to: storeURL, options: [.atomic])
    }
}
