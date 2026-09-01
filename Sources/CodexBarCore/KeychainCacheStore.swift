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
        /// The item exists, but its ACL cannot authorize this process without showing UI.
        case interactionRequired
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
    @TaskLocal private static var serviceOverride: String?
    @TaskLocal private static var forceImplicitTestStore = false
    @TaskLocal private static var forceRealKeychainPath = false
    #if DEBUG
    @TaskLocal private static var operationRecorder: OperationRecorder?
    @TaskLocal static var taskInteractionRequiredNowOverride: Date?
    @TaskLocal static var taskInteractionRequiredRetryIntervalOverride: TimeInterval?

    enum Operation: Equatable, Sendable {
        case load
        case store
        case clear
    }

    final class OperationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedOperations: [Operation] = []

        var operations: [Operation] {
            self.lock.withLock { self.recordedOperations }
        }

        func record(_ operation: Operation) {
            self.lock.withLock {
                self.recordedOperations.append(operation)
            }
        }
    }
    #endif
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
    // Repeated legacy ACL validation can accumulate Security.framework allocations. Share a cooldown
    // across every cache operation, while still recovering after an external repair without a restart.
    private static let interactionRequiredCacheLock = NSLock()
    private nonisolated(unsafe) static var interactionRequiredRetryDates: [TestStoreKey: Date] = [:]
    private static let interactionRequiredRetryInterval: TimeInterval = 5 * 60

    public static func load<Entry: Codable>(
        key: Key,
        as type: Entry.Type = Entry.self) -> LoadResult<Entry>
    {
        #if DEBUG
        self.operationRecorder?.record(.load)
        #endif
        #if DEBUG && os(macOS)
        if let status = self.loadFailureStatusOverride {
            return self.loadResultForKeychainReadFailure(status: status, key: key)
        }
        #endif
        if !self.forceRealKeychainPath,
           let testResult = loadFromTestStore(key: key, as: type),
           !self.prefersDisabledAccessMemoryStoreOverTestStore
        {
            return testResult
        }
        if self.shouldUseDisabledAccessMemoryStore(for: key.category) {
            return self.loadFromDisabledAccessMemory(key: key, as: type)
        }
        guard self.canUseRealKeychain else { return .missing }
        #if os(macOS)
        guard !self.interactionRequiredIsCached(for: key) else { return .interactionRequired }
        // Requesting secret bytes can surface a legacy ACL prompt even when the query carries
        // `kSecUseAuthenticationUIFail`. Probe attributes and the item reference first, then ask
        // for data only when the decrypt ACL already trusts this exact executable without UI.
        switch KeychainAccessPreflight.checkGenericPassword(
            service: self.serviceName,
            account: key.account)
        {
        case .allowed:
            break
        case .interactionRequired:
            self.log.info("Keychain cache item is unavailable without interaction (\(key.account))")
            self.cacheInteractionRequired(for: key)
            return .interactionRequired
        case .temporarilyUnavailable:
            self.log.info("Keychain cache temporarily unavailable (\(key.account)), will retry on next access")
            return .temporarilyUnavailable
        case .notFound:
            return .missing
        case let .failure(status):
            return self.loadResultForKeychainReadFailure(status: OSStatus(status), key: key)
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
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
        #if DEBUG
        self.operationRecorder?.record(.store)
        #endif
        #if DEBUG && os(macOS)
        if let status = self.storeFailureStatusOverride {
            self.log.error("Keychain cache store failed (\(key.account)): \(status)")
            return false
        }
        #endif
        if !self.forceRealKeychainPath,
           !self.prefersDisabledAccessMemoryStoreOverTestStore,
           let stored = self.storeInTestStore(key: key, entry: entry)
        {
            return stored
        }
        if self.shouldUseDisabledAccessMemoryStore(for: key.category) {
            return self.storeInDisabledAccessMemory(key: key, entry: entry)
        }
        guard self.canUseRealKeychain else { return false }
        #if os(macOS)
        guard !self.interactionRequiredIsCached(for: key) else { return false }
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(entry) else {
            self.log.error("Failed to encode keychain cache (\(key.account))")
            return false
        }

        let preflight = KeychainAccessPreflight.checkGenericPassword(
            service: self.serviceName,
            account: key.account)
        switch preflight {
        case .allowed, .notFound:
            break
        case .interactionRequired:
            self.log.info("Keychain cache store requires interaction (\(key.account)); skipping")
            self.cacheInteractionRequired(for: key)
            return false
        case .temporarilyUnavailable:
            self.log.info("Keychain cache store temporarily unavailable (\(key.account)); skipping")
            return false
        case let .failure(status):
            self.log.error("Keychain cache store preflight failed (\(key.account)): \(status)")
            return false
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        KeychainNoUIQuery.apply(to: &query)

        if case .allowed = preflight {
            let updateStatus = KeychainSecurity.update(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            if updateStatus == errSecSuccess {
                return true
            }
            if updateStatus != errSecItemNotFound {
                self.log.error("Keychain cache update failed (\(key.account)): \(updateStatus)")
                return false
            }
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = self.cacheLabel
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let access = self.cacheAccessControl() {
            addQuery[kSecAttrAccess as String] = access
        }

        let addStatus = KeychainSecurity.add(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another first-party process may have inserted the same cache item after our missing preflight.
            // Revalidate its ACL before resolving the benign race with an update.
            guard case .allowed = KeychainAccessPreflight.checkGenericPassword(
                service: self.serviceName,
                account: key.account)
            else { return false }
            return KeychainSecurity.update(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
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
        #if DEBUG
        self.operationRecorder?.record(.clear)
        #endif
        #if DEBUG && os(macOS)
        if let status = self.clearFailureStatusOverride {
            return self.clearResultForKeychainDeleteStatus(status, key: key)
        }
        #endif
        if !self.forceRealKeychainPath,
           !self.prefersDisabledAccessMemoryStoreOverTestStore,
           let removed = self.clearTestStore(key: key)
        {
            return removed ? .removed : .missing
        }
        if self.shouldUseDisabledAccessMemoryStore(for: key.category) {
            return self.clearDisabledAccessMemory(key: key) ? .removed : .missing
        }
        guard self.canUseRealKeychain else { return .failed }
        #if os(macOS)
        guard !self.interactionRequiredIsCached(for: key) else { return .failed }
        switch KeychainAccessPreflight.checkGenericPassword(
            service: self.serviceName,
            account: key.account)
        {
        case .allowed:
            break
        case .notFound:
            return .missing
        case .interactionRequired:
            self.log.info("Keychain cache delete requires interaction (\(key.account)); skipping")
            self.cacheInteractionRequired(for: key)
            return .failed
        case .temporarilyUnavailable:
            self.log.info("Keychain cache delete temporarily unavailable (\(key.account))")
            return .failed
        case let .failure(status):
            self.log.error("Keychain cache delete preflight failed (\(key.account)): \(status)")
            return .failed
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        KeychainNoUIQuery.apply(to: &query)
        return self.clearResultForKeychainDeleteStatus(KeychainSecurity.delete(query as CFDictionary), key: key)
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
        if !self.forceRealKeychainPath,
           !self.prefersDisabledAccessMemoryStoreOverTestStore,
           let keys = self.keysFromTestStore(category: category)
        {
            return .found(keys)
        }
        if self.shouldUseDisabledAccessMemoryStore(for: category) {
            return .found(self.keysFromDisabledAccessMemory(category: category))
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
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        return self.keysResultForKeychainStatus(status, category: category, result: result)
        #else
        return .failed
        #endif
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
        isolation _: isolated (any Actor)? = #isolation,
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

    static func withImplicitTestStoreForTesting<T>(
        operation: () throws -> T) rethrows -> T
    {
        try self.$forceImplicitTestStore.withValue(true) {
            try operation()
        }
    }

    static func withImplicitTestStoreForTesting<T>(
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$forceImplicitTestStore.withValue(true) {
            try await operation()
        }
    }

    public static var currentServiceOverrideForTesting: String? {
        self.serviceOverride
    }

    #if DEBUG
    static func withRealKeychainPathForTesting<T>(
        operation: () throws -> T) rethrows -> T
    {
        try self.$forceRealKeychainPath.withValue(true) {
            try operation()
        }
    }

    static func withOperationRecorderForTesting<T>(
        _ recorder: OperationRecorder?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$operationRecorder.withValue(recorder) {
            try operation()
        }
    }

    static func withOperationRecorderForTesting<T>(
        _ recorder: OperationRecorder?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$operationRecorder.withValue(recorder) {
            try await operation()
        }
    }

    static var currentOperationRecorderForTesting: OperationRecorder? {
        self.operationRecorder
    }
    #endif

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

    public static func withLoadFailureStatusOverrideForTesting<T>(
        _ status: OSStatus?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$loadFailureStatusOverride.withValue(status) {
            try await operation()
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

    public static func withClearFailureStatusOverrideForTesting<T>(
        _ status: OSStatus?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$clearFailureStatusOverride.withValue(status) {
            try await operation()
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
        serviceOverride ?? self.cacheService
    }

    private static var canUseRealKeychain: Bool {
        !KeychainAccessGate.isDisabled
    }

    /// When persistent cookie-cache access is unavailable, keep an in-process cache so session
    /// reconciliation can still succeed without treating every refresh as a session change.
    /// Unit tests keep using the isolated test stores instead, unless a test explicitly opts in.
    private static func shouldUseDisabledAccessMemoryStore(for category: String) -> Bool {
        #if DEBUG
        if self.disabledAccessMemoryStoreEnabledForTesting == true ||
            self.bundledAdHocProcessOverrideForTesting == true
        {
            return category == "cookie"
        }
        if KeychainTestSafety.isRunningUnderTests(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment)
        {
            return false
        }
        #endif
        // Unbundled processes (no .app ancestor: `swift build` binaries, dev CLI
        // runs) must never touch the shared cache item. Creating it would freeze
        // a trusted-application ACL onto an ephemeral unsigned binary — after
        // which the real app prompts forever — and reading someone else's item
        // raises the login-keychain password dialog. They get a process-local
        // in-memory cache instead.
        if self.isUnbundledProcess {
            return true
        }
        guard category == "cookie" else { return false }
        return KeychainAccessGate.isExplicitlyDisabled || self.isBundledAdHocProcess
    }

    /// True when the running executable has no `.app` bundle ancestor.
    static let isUnbundledProcess: Bool = {
        #if os(macOS)
        if Self.appBundleURL(containing: Bundle.main.bundleURL) != nil {
            return false
        }
        if let executableURL = Bundle.main.executableURL,
           Self.appBundleURL(containing: executableURL) != nil
        {
            return false
        }
        return true
        #else
        // No app bundles (or real keychain) exist off macOS; the memory store is
        // the only sensible backing there anyway.
        return true
        #endif
    }()

    #if DEBUG
    @TaskLocal private static var disabledAccessMemoryStoreEnabledForTesting: Bool?

    static func withDisabledAccessMemoryStoreForTesting<T>(
        _ enabled: Bool,
        operation: () throws -> T) rethrows -> T
    {
        try self.$disabledAccessMemoryStoreEnabledForTesting.withValue(enabled) {
            try operation()
        }
    }

    static func withDisabledAccessMemoryStoreForTesting<T>(
        _ enabled: Bool,
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$disabledAccessMemoryStoreEnabledForTesting.withValue(enabled) {
            try await operation()
        }
    }

    static func resetDisabledAccessMemoryStoreForTesting() {
        self.clearDisabledAccessMemoryStore()
    }
    #endif

    /// Drops the in-process fallback used when persistent cookie-cache access is unavailable.
    static func clearDisabledAccessMemoryStore() {
        self.disabledAccessMemoryLock.lock()
        self.disabledAccessMemoryStore.removeAll()
        self.disabledAccessMemoryLock.unlock()
    }

    private static let disabledAccessMemoryLock = NSLock()
    private nonisolated(unsafe) static var disabledAccessMemoryStore: [TestStoreKey: Data] = [:]

    private static var prefersDisabledAccessMemoryStoreOverTestStore: Bool {
        #if DEBUG
        self.disabledAccessMemoryStoreEnabledForTesting == true ||
            self.bundledAdHocProcessOverrideForTesting == true
        #else
        false
        #endif
    }

    #if DEBUG
    private static var shouldUseImplicitTestStore: Bool {
        KeychainTestSafety.isRunningUnderTests(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment) && !self.canUseRealKeychain
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

    static func createTrustedApplication(path: String) -> (OSStatus, SecTrustedApplication?) {
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
        guard let store = self.forceImplicitTestStore
            ? self.implicitTestStore
            : self.testStore ?? (self.shouldUseImplicitTestStore ? self.implicitTestStore : nil)
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
        if self.forceImplicitTestStore {
            self.implicitTestStore[testKey] = data
            return true
        }
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
        if self.forceImplicitTestStore {
            return self.implicitTestStore.removeValue(forKey: testKey) != nil
        }
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
        guard let store = self.forceImplicitTestStore
            ? self.implicitTestStore
            : self.testStore ?? (self.shouldUseImplicitTestStore ? self.implicitTestStore : nil)
        else { return nil }
        return store.keys
            .filter { $0.service == self.serviceName }
            .compactMap { self.key(fromAccount: $0.account, category: category) }
            .sorted { $0.identifier < $1.identifier }
    }

    private static func loadFromDisabledAccessMemory<Entry: Codable>(
        key: Key,
        as type: Entry.Type) -> LoadResult<Entry>
    {
        self.disabledAccessMemoryLock.lock()
        defer { self.disabledAccessMemoryLock.unlock() }
        let memoryKey = TestStoreKey(service: self.serviceName, account: key.account)
        guard let data = self.disabledAccessMemoryStore[memoryKey] else { return .missing }
        let decoder = Self.makeDecoder()
        guard let decoded = try? decoder.decode(Entry.self, from: data) else {
            return .invalid
        }
        return .found(decoded)
    }

    private static func storeInDisabledAccessMemory(key: Key, entry: some Codable) -> Bool {
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(entry) else { return false }
        self.disabledAccessMemoryLock.lock()
        defer { self.disabledAccessMemoryLock.unlock() }
        let memoryKey = TestStoreKey(service: self.serviceName, account: key.account)
        self.disabledAccessMemoryStore[memoryKey] = data
        self.log.debug("Cookie cache stored in process memory", metadata: [
            "account": key.account,
        ])
        return true
    }

    private static func clearDisabledAccessMemory(key: Key) -> Bool {
        self.disabledAccessMemoryLock.lock()
        defer { self.disabledAccessMemoryLock.unlock() }
        let memoryKey = TestStoreKey(service: self.serviceName, account: key.account)
        return self.disabledAccessMemoryStore.removeValue(forKey: memoryKey) != nil
    }

    private static func keysFromDisabledAccessMemory(category: String) -> [Key] {
        self.disabledAccessMemoryLock.lock()
        defer { self.disabledAccessMemoryLock.unlock() }
        return self.disabledAccessMemoryStore.keys
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

extension KeychainCacheStore {
    fileprivate static func interactionRequiredIsCached(for key: Key) -> Bool {
        self.interactionRequiredRetryDate(for: key) != nil
    }

    static func interactionRequiredRetryDate(for key: Key) -> Date? {
        self.interactionRequiredCacheLock.withLock {
            let cacheKey = TestStoreKey(service: self.serviceName, account: key.account)
            guard let retryDate = self.interactionRequiredRetryDates[cacheKey] else { return nil }
            guard self.interactionRequiredNow < retryDate else {
                self.interactionRequiredRetryDates.removeValue(forKey: cacheKey)
                return nil
            }
            return retryDate
        }
    }

    fileprivate static func cacheInteractionRequired(for key: Key) {
        self.interactionRequiredCacheLock.withLock {
            self.interactionRequiredRetryDates[TestStoreKey(service: self.serviceName, account: key.account)] =
                self.interactionRequiredNow.addingTimeInterval(self.currentInteractionRequiredRetryInterval)
        }
    }

    private static var interactionRequiredNow: Date {
        #if DEBUG
        if let override = self.taskInteractionRequiredNowOverride {
            return override
        }
        #endif
        return Date()
    }

    private static var currentInteractionRequiredRetryInterval: TimeInterval {
        #if DEBUG
        if let override = self.taskInteractionRequiredRetryIntervalOverride {
            return override
        }
        #endif
        return self.interactionRequiredRetryInterval
    }
}

extension KeychainCacheStore.Key {
    public static func cookie(provider instanceID: ProviderInstanceID, scopeIdentifier: String? = nil) -> Self {
        let identifier: String = if let scopeIdentifier, !scopeIdentifier.isEmpty {
            "\(instanceID.rawValue).\(scopeIdentifier)"
        } else {
            instanceID.rawValue
        }
        return Self(category: "cookie", identifier: identifier)
    }

    public static func oauth(provider instanceID: ProviderInstanceID) -> Self {
        Self(category: "oauth", identifier: instanceID.rawValue)
    }
}
