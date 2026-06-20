import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CookieHeaderCacheConditionalMutationTests {
    #if os(macOS)
    @Test
    func `temporary keychain read permits fresh replacement when legacy state is unchanged`() {
        self.withIsolatedCookieCache {
            let legacy = CookieHeaderCache.Entry(
                cookieHeader: "sessionKey=sk-ant-legacy",
                storedAt: Date(timeIntervalSince1970: 1),
                sourceLabel: "Legacy")
            CookieHeaderCache.store(legacy, to: CookieHeaderCache.legacyURLForTesting(provider: .claude))

            let observation = KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                CookieHeaderCache.observeForConditionalMutation(provider: .claude)
            }
            let replaced = CookieHeaderCache.storeIfObservationCurrent(
                provider: .claude,
                expected: observation,
                cookieHeader: "sessionKey=sk-ant-fresh",
                sourceLabel: "Safari")

            #expect(observation.entry == nil)
            #expect(replaced)
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-fresh")
            #expect(!CookieHeaderCache.hasLegacyEntryForTesting(provider: .claude))
        }
    }

    @Test
    func `temporary keychain read does not overwrite a concurrent keychain entry`() {
        self.withIsolatedCookieCache {
            let observation = KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                CookieHeaderCache.observeForConditionalMutation(provider: .claude)
            }
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-concurrent",
                sourceLabel: "Chrome")

            let replaced = CookieHeaderCache.storeIfObservationCurrent(
                provider: .claude,
                expected: observation,
                cookieHeader: "sessionKey=sk-ant-fresh",
                sourceLabel: "Safari")

            #expect(!replaced)
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-concurrent")
        }
    }
    #endif

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
            return CookieHeaderCache.withLegacyBaseURLOverrideForTesting(legacyBase) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                return operation()
            }
        }
    }
}
