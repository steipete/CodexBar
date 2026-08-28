import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthPendingCacheClearStoreTests {
    @Test
    func `legacy ownership recheck persists for only its invalidated profile`() throws {
        let domain = "ClaudeOAuthPendingLegacyRecheckTests.\(UUID().uuidString)"
        let key = "pending"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userDefaults = try #require(UserDefaults(suiteName: domain))
        defer {
            userDefaults.removePersistentDomain(forName: domain)
            userDefaults.synchronize()
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        let lockURL = tempDirectory.appendingPathComponent("cache.lock")
        let store = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            domain: domain,
            key: key,
            lockURL: lockURL)
        store.withCacheTransaction(
            profileIdentifier: "profile-a",
            includingLegacyState: { profilePending, legacyCleanupPending, legacyRecheckPending in
                #expect(!profilePending)
                #expect(!legacyCleanupPending)
                #expect(!legacyRecheckPending)
                legacyRecheckPending = true
            })

        let reloadedStore = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            domain: domain,
            key: key,
            lockURL: lockURL)
        #expect(reloadedStore.isPending(profileIdentifier: "profile-a"))
        #expect(!reloadedStore.isPending(profileIdentifier: "profile-b"))
        reloadedStore.withCacheTransaction(
            profileIdentifier: "profile-a",
            includingLegacyState: { profilePending, legacyCleanupPending, legacyRecheckPending in
                #expect(!profilePending)
                #expect(!legacyCleanupPending)
                #expect(legacyRecheckPending)
                legacyRecheckPending = false
            })
        #expect(!reloadedStore.isPending)
    }

    @Test
    func `profile lock failure remains owned by the invalidated profile`() throws {
        let domain = "ClaudeOAuthPendingProfileLockFailureTests.\(UUID().uuidString)"
        let key = "pending"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let blockedLockDirectory = tempDirectory.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedLockDirectory)
        let userDefaults = try #require(UserDefaults(suiteName: domain))
        defer {
            userDefaults.removePersistentDomain(forName: domain)
            userDefaults.synchronize()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let store = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            domain: domain,
            key: key,
            lockURL: blockedLockDirectory.appendingPathComponent("cache.lock"))
        store.markPending(profileIdentifier: "profile-a")
        userDefaults.synchronize()

        #expect(userDefaults.object(forKey: key) == nil)

        try FileManager.default.removeItem(at: blockedLockDirectory)
        try FileManager.default.createDirectory(at: blockedLockDirectory, withIntermediateDirectories: true)

        #expect(store.isPending(profileIdentifier: "profile-a"))
        #expect(!store.isPending(profileIdentifier: "profile-b"))
        store.withCacheTransaction(profileIdentifier: "profile-b") { pending in
            #expect(!pending)
        }
        #expect(store.isPending(profileIdentifier: "profile-a"))
        #expect(!store.isPending(profileIdentifier: "profile-b"))

        store.withCacheTransaction(profileIdentifier: "profile-a") { pending in
            #expect(pending)
            pending = false
        }
        #expect(!store.isPending)
    }
}
