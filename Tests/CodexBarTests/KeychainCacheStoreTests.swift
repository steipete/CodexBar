import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct KeychainCacheStoreTests {
    struct TestEntry: Codable, Equatable {
        let value: String
        let storedAt: Date
    }

    @Test
    func `stores and loads entry`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let storedAt = Date(timeIntervalSince1970: 0)
        let entry = TestEntry(value: "alpha", storedAt: storedAt)

        KeychainCacheStore.store(key: key, entry: entry)
        defer { KeychainCacheStore.clear(key: key) }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == entry)
        case .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected keychain cache entry")
        }
    }

    @Test
    func `overwrites existing entry`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let first = TestEntry(value: "first", storedAt: Date(timeIntervalSince1970: 1))
        let second = TestEntry(value: "second", storedAt: Date(timeIntervalSince1970: 2))

        KeychainCacheStore.store(key: key, entry: first)
        KeychainCacheStore.store(key: key, entry: second)
        defer { KeychainCacheStore.clear(key: key) }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == second)
        case .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected overwritten keychain cache entry")
        }
    }

    @Test
    func `clear removes entry`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "gone", storedAt: Date(timeIntervalSince1970: 0))

        KeychainCacheStore.store(key: key, entry: entry)
        KeychainCacheStore.clear(key: key)

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case .missing:
            #expect(true)
        case .found, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected keychain cache entry to be cleared")
        }
    }

    @Test
    func `clear reports whether an entry was removed`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "gone", storedAt: Date(timeIntervalSince1970: 0))
        KeychainCacheStore.store(key: key, entry: entry)

        #expect(KeychainCacheStore.clear(key: key) == true)
        #expect(KeychainCacheStore.clear(key: key) == false)
    }

    @Test
    func `keys lists only matching category for current service`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let serviceA = "cache-keys-a-\(UUID().uuidString)"
        let serviceB = "cache-keys-b-\(UUID().uuidString)"
        let cookieA = KeychainCacheStore.Key(category: "cookie", identifier: "codex")
        let scopedCookieA = KeychainCacheStore.Key(category: "cookie", identifier: "codex.managed.account")
        let oauthA = KeychainCacheStore.Key(category: "oauth", identifier: "codex")
        let cookieB = KeychainCacheStore.Key(category: "cookie", identifier: "claude")
        let entry = TestEntry(value: "value", storedAt: Date(timeIntervalSince1970: 0))

        KeychainCacheStore.withServiceOverrideForTesting(serviceA) {
            KeychainCacheStore.store(key: cookieA, entry: entry)
            KeychainCacheStore.store(key: scopedCookieA, entry: entry)
            KeychainCacheStore.store(key: oauthA, entry: entry)
        }
        KeychainCacheStore.withServiceOverrideForTesting(serviceB) {
            KeychainCacheStore.store(key: cookieB, entry: entry)
        }

        let keys = KeychainCacheStore.withServiceOverrideForTesting(serviceA) {
            KeychainCacheStore.keys(category: "cookie")
        }

        #expect(keys == [cookieA, scopedCookieA])
    }

    #if os(macOS)
    @Test
    func `interaction not allowed is treated as temporarily unavailable`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let result: KeychainCacheStore.LoadResult<TestEntry> = KeychainCacheStore.loadResultForKeychainReadFailure(
            status: errSecInteractionNotAllowed,
            key: key)

        switch result {
        case .temporarilyUnavailable:
            #expect(true)
        case .found, .missing, .invalid:
            #expect(Bool(false), "Expected temporary keychain lock to be retry-later")
        }
    }

    @Test
    func `load failure override bypasses test store without affecting store or clear`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "stored", storedAt: Date(timeIntervalSince1970: 0))
        KeychainCacheStore.store(key: key, entry: entry)
        defer { KeychainCacheStore.clear(key: key) }

        KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
            case .temporarilyUnavailable:
                #expect(true)
            case .found, .missing, .invalid:
                #expect(Bool(false), "Expected override to run before test store")
            }
        }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == entry)
        case .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected override not to mutate test store")
        }
    }
    #endif
}
