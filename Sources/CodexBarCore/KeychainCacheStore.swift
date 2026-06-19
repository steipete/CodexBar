import Foundation
#if os(macOS)
import Darwin
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

    public enum ClearResult: Equatable, Sendable {
        case removed
        case missing
        case failed
    }

    public enum KeysResult: Equatable, Sendable {
        case found([Key])
        case temporarilyUnavailable
        case failed
    }

    private static let log = CodexBarLog.logger(LogCategories.keychainCache)
    private static let cacheService = "com.steipete.codexbar.cache"
    private static let cacheLabel = "CodexBar Cache"
    private nonisolated(unsafe) static var globalServiceOverride: String?
    @TaskLocal private static var serviceOverride: String?
    #if DEBUG && os(macOS)
    @TaskLocal private static var loadFailureStatusOverride: OSStatus?
    @TaskLocal private static var storeFailureStatusOverride: OSStatus?
    @TaskLocal private static var clearFailureStatusOverride: OSStatus?
    @TaskLocal private static var keysFailureStatusOverride: OSStatus?
    #endif
    private static let testStoreLock = NSLock()
    private struct TestStoreKey: Hashable {
        let service: String
        let account: String
    }

    private nonisolated(unsafe) static var testStore: [TestStoreKey: Data]?
    private nonisolated(unsafe) static var implicitTestStore: [TestStoreKey: Data] = [:]
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
        guard self.canUseRealKeychain else { return .missing }
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
        _ = self.storeResult(key: key, entry: entry)
    }

    @discardableResult
    public static func storeResult(key: Key, entry: some Codable) -> Bool {
        #if DEBUG && os(macOS)
        if let status = self.storeFailureStatusOverride {
            self.log.error("Keychain cache store failed (\(key.account)): \(status)")
            return false
        }
        #endif
        if let stored = self.storeInTestStore(key: key, entry: entry) {
            return stored
        }
        guard self.canUseRealKeychain else { return false }
        #if os(macOS)
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(entry) else {
            self.log.error("Failed to encode keychain cache (\(key.account))")
            return false
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        KeychainNoUIQuery.apply(to: &query)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            self.log.error("Keychain cache update failed (\(key.account)): \(updateStatus)")
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = self.cacheLabel
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let access = self.cacheAccessControl() {
            addQuery[kSecAttrAccess as String] = access
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            self.log.error("Keychain cache add failed (\(key.account)): \(addStatus)")
        }
        return addStatus == errSecSuccess
        #else
        return false
        #endif
    }

    @discardableResult
    public static func clear(key: Key) -> Bool {
        self.clearResult(key: key) == .removed
    }

    public static func clearResult(key: Key) -> ClearResult {
        #if DEBUG && os(macOS)
        if let status = self.clearFailureStatusOverride {
            return self.clearResultForKeychainDeleteStatus(status, key: key)
        }
        #endif
        if let removed = self.clearTestStore(key: key) {
            return removed ? .removed : .missing
        }
        guard self.canUseRealKeychain else { return .failed }
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        KeychainNoUIQuery.apply(to: &query)
        return self.clearResultForKeychainDeleteStatus(SecItemDelete(query as CFDictionary), key: key)
        #else
        return .failed
        #endif
    }

    public static func keys(category: String) -> [Key] {
        switch self.keysResult(category: category) {
        case let .found(keys):
            keys
        case .temporarilyUnavailable, .failed:
            []
        }
    }

    public static func keysResult(category: String) -> KeysResult {
        #if DEBUG && os(macOS)
        if let status = self.keysFailureStatusOverride {
            return self.keysResultForKeychainStatus(status, category: category, result: nil)
        }
        #endif
        if let keys = self.keysFromTestStore(category: category) {
            return .found(keys)
        }
        guard self.canUseRealKeychain else { return .failed }
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
        return self.keysResultForKeychainStatus(status, category: category, result: result)
        #else
        return .failed
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

    static var canUseRealKeychainForTesting: Bool {
        self.canUseRealKeychain
    }

    static var canEnumerateOrDeleteRealKeychainForTesting: Bool {
        self.canUseRealKeychain
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

    public static func withStoreFailureStatusOverrideForTesting<T>(
        _ status: OSStatus?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$storeFailureStatusOverride.withValue(status) {
            try operation()
        }
    }

    public static func withClearFailureStatusOverrideForTesting<T>(
        _ status: OSStatus?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$clearFailureStatusOverride.withValue(status) {
            try operation()
        }
    }

    public static func withKeysFailureStatusOverrideForTesting<T>(
        _ status: OSStatus?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$keysFailureStatusOverride.withValue(status) {
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

    private static var canUseRealKeychain: Bool {
        !KeychainAccessGate.isDisabled
    }

    #if DEBUG
    private static var shouldUseImplicitTestStore: Bool {
        self.isRunningUnderTests && !self.canUseRealKeychain
    }

    private static var isRunningUnderTests: Bool {
        let processName = ProcessInfo.processInfo.processName
        return processName == "swiftpm-testing-helper"
            || processName.hasSuffix("PackageTests")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    #else
    private static var shouldUseImplicitTestStore: Bool {
        false
    }
    #endif

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

    static func clearResultForKeychainDeleteStatus(_ status: OSStatus, key: Key) -> ClearResult {
        switch status {
        case errSecSuccess:
            return .removed
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            self.log.info("Keychain cache delete temporarily unavailable (\(key.account))")
            return .failed
        default:
            self.log.error("Keychain cache delete failed (\(key.account)): \(status)")
            return .failed
        }
    }

    private static func keysResultForKeychainStatus(
        _ status: OSStatus,
        category: String,
        result: AnyObject?) -> KeysResult
    {
        switch status {
        case errSecSuccess:
            guard let rows = result as? [[String: Any]] else { return .failed }
            let keys: [Key] = rows.compactMap { row in
                guard let account = row[kSecAttrAccount as String] as? String else { return nil }
                return self.key(fromAccount: account, category: category)
            }
            return .found(keys)
        case errSecItemNotFound:
            return .found([])
        case errSecInteractionNotAllowed:
            self.log.info("Keychain cache keys temporarily unavailable (\(category))")
            return .temporarilyUnavailable
        default:
            self.log.error("Keychain cache key listing failed (\(category)): \(status)")
            return .failed
        }
    }

    static func trustedApplicationPathsForCacheAccess(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]
    {
        var paths: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, fileExists(path), !paths.contains(path) else { return }
            paths.append(path)
        }

        let appBundle = self.appBundleURL(containing: bundleURL)
            ?? executableURL.flatMap(self.appBundleURL(containing:))
        if let appBundle {
            append(appBundle.path)
            append(appBundle.appendingPathComponent("Contents/Helpers/CodexBarCLI").path)
        }
        if let executableURL {
            append(executableURL.path)
        }
        return paths
    }

    private static func appBundleURL(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private static func cacheAccessControl() -> SecAccess? {
        let trustedPaths = self.trustedApplicationPathsForCacheAccess()
        guard !trustedPaths.isEmpty else { return nil }

        var trustedApplications: [SecTrustedApplication] = []
        for path in trustedPaths {
            let (status, application) = self.createTrustedApplication(path: path)
            if status == errSecSuccess, let application {
                trustedApplications.append(application)
            } else {
                self.log.error("Keychain cache trusted app creation failed (\(path)): \(status)")
            }
        }
        guard !trustedApplications.isEmpty else { return nil }

        let (status, access) = self.createAccessControl(trustedApplications: trustedApplications)
        if status != errSecSuccess {
            self.log.error("Keychain cache access control creation failed: \(status)")
            return nil
        }
        return access
    }

    private typealias SecTrustedApplicationCreateFromPathFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<SecTrustedApplication?>?) -> OSStatus
    private typealias SecAccessCreateFunction = @convention(c) (
        CFString,
        CFArray,
        UnsafeMutablePointer<SecAccess?>?) -> OSStatus

    private static func createTrustedApplication(path: String) -> (OSStatus, SecTrustedApplication?) {
        guard let symbol = self.securitySymbol(named: "SecTrustedApplicationCreateFromPath") else {
            return (errSecInternalComponent, nil)
        }
        let function = unsafeBitCast(symbol, to: SecTrustedApplicationCreateFromPathFunction.self)
        var application: SecTrustedApplication?
        let status = path.withCString { cPath in
            function(cPath, &application)
        }
        return (status, application)
    }

    private static func createAccessControl(trustedApplications: [SecTrustedApplication]) -> (OSStatus, SecAccess?) {
        guard let symbol = self.securitySymbol(named: "SecAccessCreate") else {
            return (errSecInternalComponent, nil)
        }
        let function = unsafeBitCast(symbol, to: SecAccessCreateFunction.self)
        var access: SecAccess?
        let status = function(self.cacheLabel as CFString, trustedApplications as CFArray, &access)
        return (status, access)
    }

    private nonisolated(unsafe) static let securityFrameworkHandle: UnsafeMutableRawPointer? = {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        return dlopen(securityPath, RTLD_NOW)
    }()

    private static func securitySymbol(named name: String) -> UnsafeMutableRawPointer? {
        // Resolve deprecated SecKeychain ACL helpers at runtime so release builds stay warning-free
        // while still granting the app bundle and bundled CLI prompt-free access to cache entries.
        guard let securityFrameworkHandle else { return nil }
        return dlsym(securityFrameworkHandle, name)
    }
    #endif

    private static func loadFromTestStore<Entry: Codable>(
        key: Key,
        as type: Entry.Type) -> LoadResult<Entry>?
    {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard let store = self.testStore ?? (self.shouldUseImplicitTestStore ? self.implicitTestStore : nil)
        else { return nil }
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
        guard let data = store[testKey] else { return .missing }
        let decoder = Self.makeDecoder()
        guard let decoded = try? decoder.decode(Entry.self, from: data) else {
            return .invalid
        }
        return .found(decoded)
    }

    private static func storeInTestStore(key: Key, entry: some Codable) -> Bool? {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(entry) else { return false }
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
        if var store = self.testStore {
            store[testKey] = data
            self.testStore = store
            return true
        }
        if self.shouldUseImplicitTestStore {
            self.implicitTestStore[testKey] = data
            return true
        }
        return nil
    }

    private static func clearTestStore(key: Key) -> Bool? {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
        if var store = self.testStore {
            let removed = store.removeValue(forKey: testKey) != nil
            self.testStore = store
            return removed
        }
        if self.shouldUseImplicitTestStore {
            return self.implicitTestStore.removeValue(forKey: testKey) != nil
        }
        return nil
    }

    private static func keysFromTestStore(category: String) -> [Key]? {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard let store = self.testStore ?? (self.shouldUseImplicitTestStore ? self.implicitTestStore : nil)
        else { return nil }
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
