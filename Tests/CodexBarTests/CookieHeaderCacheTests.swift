import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CookieHeaderCacheTests {
    @Test
    func `stores and loads entry`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let provider: UsageProvider = .codex
        let storedAt = Date(timeIntervalSince1970: 0)
        CookieHeaderCache.store(
            provider: provider,
            cookieHeader: "auth=abc",
            sourceLabel: "Chrome",
            now: storedAt)

        let loaded = CookieHeaderCache.load(provider: provider)
        defer { CookieHeaderCache.clear(provider: provider) }

        #expect(loaded?.cookieHeader == "auth=abc")
        #expect(loaded?.sourceLabel == "Chrome")
        #expect(loaded?.storedAt == storedAt)
    }

    @Test
    func `stores separate codex entries per managed account scope`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let provider: UsageProvider = .codex
        let accountA = UUID()
        let accountB = UUID()

        CookieHeaderCache.store(
            provider: provider,
            scope: .managedAccount(accountA),
            cookieHeader: "auth=account-a",
            sourceLabel: "Chrome")
        CookieHeaderCache.store(
            provider: provider,
            scope: .managedAccount(accountB),
            cookieHeader: "auth=account-b",
            sourceLabel: "Safari")
        defer {
            CookieHeaderCache.clear(provider: provider, scope: .managedAccount(accountA))
            CookieHeaderCache.clear(provider: provider, scope: .managedAccount(accountB))
        }

        #expect(CookieHeaderCache.load(provider: provider, scope: .managedAccount(accountA))?
            .cookieHeader == "auth=account-a")
        #expect(CookieHeaderCache.load(provider: provider, scope: .managedAccount(accountB))?
            .cookieHeader == "auth=account-b")
        #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == nil)
    }

    @Test
    func `provider global scope remains available without managed account`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let provider: UsageProvider = .codex

        CookieHeaderCache.store(
            provider: provider,
            cookieHeader: "auth=system",
            sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: provider) }

        #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "auth=system")
        #expect(CookieHeaderCache.load(provider: provider, scope: .managedAccount(UUID())) == nil)
    }

    @Test
    func `migrates legacy file to keychain`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        let storedAt = Date(timeIntervalSince1970: 0)
        let entry = CookieHeaderCache.Entry(
            cookieHeader: "auth=legacy",
            storedAt: storedAt,
            sourceLabel: "Legacy")
        let legacyURL = legacyBase.appendingPathComponent("\(provider.rawValue)-cookie.json")

        CookieHeaderCache.store(entry, to: legacyURL)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == true)

        let loaded = CookieHeaderCache.load(provider: provider)
        defer { CookieHeaderCache.clear(provider: provider) }

        #expect(loaded?.cookieHeader == "auth=legacy")
        #expect(loaded?.sourceLabel == "Legacy")
        #expect(loaded?.storedAt == storedAt)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)

        let loadedAgain = CookieHeaderCache.load(provider: provider)
        #expect(loadedAgain?.cookieHeader == "auth=legacy")
    }
}
