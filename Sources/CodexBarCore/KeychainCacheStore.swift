import Foundation
#if os(macOS)
import Security
#endif

public enum KeychainCacheStore {
    public struct Key: Hashable, Sendable {
        public let category: String
        public let identifier: String

        public init(category: String, identifier: String) {
            self.category = category
            self.identifier = identifier
        }

        var account: String {
            "\(self.category).\(self.identifier)"
        }
    }

    public enum LoadResult<Entry> {
        case found(Entry)
        case missing
        case invalid
    }

    private static let log = CodexBarLog.logger(LogCategories.keychainCache)
    private static let cacheService = "com.steipete.codexbar.cache"
    private static let cacheLabel = "CodexBar Cache"
    private nonisolated(unsafe) static var globalServiceOverride: String?
    @TaskLocal private static var serviceOverride: String?
    private static let testStoreLock = NSLock()
    private struct TestStoreKey: Hashable {
        let service: String
        let account: String
    }

    private nonisolated(unsafe) static var testStore: [TestStoreKey: Data]?
    private nonisolated(unsafe) static var testStoreRefCount = 0

    public static func load<Entry: Codable>(
        key: Key,
        as type: Entry.Type = Entry.self) -> LoadResult<Entry>
    {
        if let testResult = loadFromTestStore(key: key, as: type) {
            return testResult
        }
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                self.log.error("Keychain cache item was empty (\(key.account))")
                return .invalid
            }
            let decoder = Self.makeDecoder()
            guard let decoded = try? decoder.decode(Entry.self, from: data) else {
                self.log.error("Failed to decode keychain cache (\(key.account))")
                return .invalid
            }
            return .found(decoded)
        case errSecItemNotFound:
            return .missing
        default:
            self.log.error("Keychain cache read failed (\(key.account)): \(status)")
            return .invalid
        }
        #else
        return .missing
        #endif
    }

    public static func store(key: Key, entry: some Codable) {
        if self.storeInTestStore(key: key, entry: entry) {
            return
        }
        #if os(macOS)
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(entry) else {
            self.log.error("Failed to encode keychain cache (\(key.account))")
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            self.log.error("Keychain cache update failed (\(key.account)): \(updateStatus)")
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = self.cacheLabel
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            self.log.error("Keychain cache add failed (\(key.account)): \(addStatus)")
        }
        #endif
    }

    public static func clear(key: Key) {
        if self.clearTestStore(key: key) {
            return
        }
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            self.log.error("Keychain cache delete failed (\(key.account)): \(status)")
        }
        #endif
    }

    static func setServiceOverrideForTesting(_ service: String?) {
        self.globalServiceOverride = service
    }

    static func withServiceOverrideForTesting<T>(_ service: String?, operation: () throws -> T) rethrows -> T {
        try self.$serviceOverride.withValue(service) {
            try operation()
        }
    }

    static func setTestStoreForTesting(_ enabled: Bool) {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        if enabled {
            self.testStoreRefCount += 1
            if self.testStoreRefCount == 1 {
                self.testStore = [:]
            }
        } else {
            self.testStoreRefCount = max(0, self.testStoreRefCount - 1)
            if self.testStoreRefCount == 0 {
                self.testStore = nil
            }
        }
    }

    private static var serviceName: String {
        serviceOverride ?? self.globalServiceOverride ?? self.cacheService
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func loadFromTestStore<Entry: Codable>(
        key: Key,
        as type: Entry.Type) -> LoadResult<Entry>?
    {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard let store = self.testStore else { return nil }
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
        guard let data = store[testKey] else { return .missing }
        let decoder = Self.makeDecoder()
        guard let decoded = try? decoder.decode(Entry.self, from: data) else {
            return .invalid
        }
        return .found(decoded)
    }

    private static func storeInTestStore(key: Key, entry: some Codable) -> Bool {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard var store = self.testStore else { return false }
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(entry) else { return true }
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
        store[testKey] = data
        self.testStore = store
        return true
    }

    private static func clearTestStore(key: Key) -> Bool {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard var store = self.testStore else { return false }
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
        store.removeValue(forKey: testKey)
        self.testStore = store
        return true
    }
}

extension KeychainCacheStore.Key {
    public static func cookie(provider: UsageProvider) -> Self {
        Self(category: "cookie", identifier: provider.rawValue)
    }

    public static func oauth(provider: UsageProvider) -> Self {
        Self(category: "oauth", identifier: provider.rawValue)
    }
}
