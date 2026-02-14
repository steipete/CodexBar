import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CookieHeaderCacheTests {
    @Test
    func storesAndLoadsEntry() {
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
    func migratesLegacyFileToKeychain() {
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
