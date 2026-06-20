import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CookieHeaderCacheConditionalMutationTests {
    @Test
    func `legacy clear failure still permits replacing the keychain entry`() {
        self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale",
                sourceLabel: "Chrome")
            let stale = CookieHeaderCache.load(provider: .claude)
            #expect(stale != nil)
            guard let stale else { return }

            CookieHeaderCache.store(
                CookieHeaderCache.Entry(
                    cookieHeader: "sessionKey=sk-ant-legacy",
                    storedAt: Date(timeIntervalSince1970: 1),
                    sourceLabel: "Legacy"),
                to: CookieHeaderCache.legacyURLForTesting(provider: .claude))

            let cleared = CookieHeaderCache.withLegacyRemovalFailureForTesting {
                CookieHeaderCache.clearIfCurrent(provider: .claude, expected: stale)
            }
            let replaced = CookieHeaderCache.storeIfCurrent(
                provider: .claude,
                expected: stale,
                cookieHeader: "sessionKey=sk-ant-fresh",
                sourceLabel: "Safari")

            #expect(!cleared)
            #expect(replaced)
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-fresh")
            #expect(!CookieHeaderCache.hasLegacyEntryForTesting(provider: .claude))
        }
    }

    private func withIsolatedCookieCache<T>(_ operation: () -> T) -> T {
        KeychainCacheStore.withServiceOverrideForTesting("cookie-conditional-\(UUID().uuidString)") {
            let legacyBase = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
            defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            CookieHeaderCache.resetDisplayCacheForTesting()
            defer { CookieHeaderCache.resetDisplayCacheForTesting() }
            return operation()
        }
    }
}
