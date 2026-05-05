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
        case temporarilyUnavailable
        case invalid
    }

    private static let log = CodexBarLog.logger(LogCategories.keychainCache)
    private static let cacheService = "com.steipete.codexbar.cache"
    private static let cacheLabel = "CodexBar Cache"
    private nonisolated(unsafe) static var globalServiceOverride: String?
    @TaskLocal private static var serviceOverride: String?
    #if DEBUG && os(macOS)
    @TaskLocal private static var loadFailureStatusOverride: OSStatus?
    #endif
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
        #if DEBUG && os(macOS)
        if let status = self.loadFailureStatusOverride {
            return self.loadResultForKeychainReadFailure(status: status, key: key)
        }
        #endif
        if let testResult = loadFromTestStore(key: key, as: type) {
            return testResult
        }
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

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
        default:
            return self.loadResultForKeychainReadFailure(status: status, key: key)
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

    @discardableResult
    public static func clear(key: Key) -> Bool {
        if let removed = self.clearTestStore(key: key) {
            return removed
        }
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status != errSecItemNotFound {
            self.log.error("Keychain cache delete failed (\(key.account)): \(status)")
        }
        #endif
        return false
    }

    public static func keys(category: String) -> [Key] {
        if let keys = self.keysFromTestStore(category: category) {
            return keys
        }
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let rows = result as? [[String: Any]] else { return [] }
            return rows.compactMap { row in
                guard let account = row[kSecAttrAccount as String] as? String else { return nil }
                return self.key(fromAccount: account, category: category)
            }
        case errSecItemNotFound:
            return []
        case errSecInteractionNotAllowed:
            self.log.info("Keychain cache keys temporarily unavailable (\(category))")
            return []
        default:
            self.log.error("Keychain cache key listing failed (\(category)): \(status)")
            return []
        }
        #else
        return []
        #endif
    }

    static func setServiceOverrideForTesting(_ service: String?) {
        self.globalServiceOverride = service
    }

    public static func withServiceOverrideForTesting<T>(
        _ service: String?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$serviceOverride.withValue(service) {
            try operation()
        }
    }

    public static func withServiceOverrideForTesting<T>(
        _ service: String?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$serviceOverride.withValue(service) {
            try await operation()
        }
    }

    public static func withCurrentServiceOverrideForTesting<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        let service = self.serviceOverride
        return try await self.$serviceOverride.withValue(service) {
            try await operation()
        }
    }

    public static var currentServiceOverrideForTesting: String? {
        self.serviceOverride
    }

    #if DEBUG && os(macOS)
    public static func withLoadFailureStatusOverrideForTesting<T>(
        _ status: OSStatus?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$loadFailureStatusOverride.withValue(status) {
            try operation()
        }
    }
    #endif

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

    #if os(macOS)
    static func loadResultForKeychainReadFailure<Entry>(
        status: OSStatus,
        key: Key) -> LoadResult<Entry>
    {
        switch status {
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            // Keychain is temporarily locked, e.g. immediately after wake from sleep.
            self.log.info("Keychain cache temporarily locked (\(key.account)), will retry on next access")
            return .temporarilyUnavailable
        default:
            self.log.error("Keychain cache read failed (\(key.account)): \(status)")
            return .invalid
        }
    }
    #endif

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

    private static func clearTestStore(key: Key) -> Bool? {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard var store = self.testStore else { return nil }
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
        let removed = store.removeValue(forKey: testKey) != nil
        self.testStore = store
        return removed
    }

    private static func keysFromTestStore(category: String) -> [Key]? {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard let store = self.testStore else { return nil }
        return store.keys
            .filter { $0.service == self.serviceName }
            .compactMap { self.key(fromAccount: $0.account, category: category) }
            .sorted { $0.identifier < $1.identifier }
    }

    private static func key(fromAccount account: String, category: String) -> Key? {
        let prefix = "\(category)."
        guard account.hasPrefix(prefix) else { return nil }
        let identifier = String(account.dropFirst(prefix.count))
        guard !identifier.isEmpty else { return nil }
        return Key(category: category, identifier: identifier)
    }
}

extension KeychainCacheStore.Key {
    public static func cookie(provider: UsageProvider, scopeIdentifier: String? = nil) -> Self {
        let identifier: String = if let scopeIdentifier, !scopeIdentifier.isEmpty {
            "\(provider.rawValue).\(scopeIdentifier)"
        } else {
            provider.rawValue
        }
        return Self(category: "cookie", identifier: identifier)
    }

    public static func oauth(provider: UsageProvider) -> Self {
        Self(category: "oauth", identifier: provider.rawValue)
    }
}
