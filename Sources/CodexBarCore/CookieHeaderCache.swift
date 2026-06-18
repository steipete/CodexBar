import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum CookieHeaderCache {
    public enum Scope: Sendable, Equatable {
        case managedAccount(UUID)
        case managedStoreUnreadable

        fileprivate var keychainIdentifier: String {
            switch self {
            case let .managedAccount(accountID):
                "managed.\(accountID.uuidString.lowercased())"
            case .managedStoreUnreadable:
                "managed-store-unreadable"
            }
        }
    }

    public struct Entry: Codable, Sendable {
        public let cookieHeader: String
        public let storedAt: Date
        public let sourceLabel: String

        public init(cookieHeader: String, storedAt: Date, sourceLabel: String) {
            self.cookieHeader = cookieHeader
            self.storedAt = storedAt
            self.sourceLabel = sourceLabel
        }
    }

    public struct ClearSummary: Equatable, Sendable {
        public let clearedCount: Int
        public let failedCount: Int

        public init(clearedCount: Int, failedCount: Int) {
            self.clearedCount = clearedCount
            self.failedCount = failedCount
        }
    }

    private static let log = CodexBarLog.logger(LogCategories.cookieCache)
    private static let legacyBaseURLOverrideLock = NSLock()
    private nonisolated(unsafe) static var legacyBaseURLOverride: URL?

    private struct DisplaySnapshot {
        let entry: Entry?
        let refreshAfter: Date
    }

    private enum LoadOutcome {
        case authoritative(Entry?, loadedFromLegacy: Bool)
        case temporarilyUnavailable
    }

    private static let legacyMutationLock = NSLock()
    private static let displayCacheLock = NSLock()
    private nonisolated(unsafe) static var displayCache: [KeychainCacheStore.Key: DisplaySnapshot] = [:]
    private nonisolated(unsafe) static var displayGenerations: [KeychainCacheStore.Key: UInt64] = [:]
    private nonisolated(unsafe) static var displayRevalidationsInFlight: Set<KeychainCacheStore.Key> = []
    private nonisolated(unsafe) static var legacyMigrationsInFlight: Set<UsageProvider> = []
    private nonisolated(unsafe) static var displayStalenessIntervalOverride: TimeInterval?
    private nonisolated(unsafe) static var displayUnavailableRetryIntervalOverride: TimeInterval?
    private static let displayStalenessInterval: TimeInterval = 30
    private static let displayUnavailableRetryInterval: TimeInterval = 1
    #if DEBUG
    @TaskLocal private static var legacyRemovalFailureOverride = false
    #endif

    private enum LegacyRemovalResult: Equatable {
        case removed
        case missing
        case failed
    }

    /// Settings rows render the "Cached: …" cookie label inside SwiftUI body evaluations, which
    /// run repeatedly within a single AppKit layout pass. Each `load` pays a synchronous
    /// securityd round-trip and decrypt, so display paths use this memoized variant instead: it
    /// returns the last known entry immediately and revalidates a stale snapshot off the calling
    /// path. In-process `store` and `clear` calls update the snapshot synchronously; only the
    /// first lookup per key pays the keychain read.
    public static func loadForDisplay(provider: UsageProvider, scope: Scope? = nil) -> Entry? {
        let key = self.key(for: provider, scope: scope)
        let (cached, generation) = self.beginDisplayRead(key: key)
        guard let cached else {
            switch self.loadOutcome(provider: provider, scope: scope, migrateLegacy: false) {
            case let .authoritative(entry, loadedFromLegacy):
                let committed = self.commitDisplaySnapshotIfCurrent(key: key, entry: entry, generation: generation)
                if loadedFromLegacy {
                    self.scheduleLegacyMigration(provider: provider)
                }
                return committed
            case .temporarilyUnavailable:
                return self.commitTemporaryDisplaySnapshotIfCurrent(key: key, generation: generation)
            }
        }
        if Date() >= cached.refreshAfter {
            self.scheduleDisplayRevalidation(provider: provider, scope: scope, key: key, generation: generation)
        }
        return cached.entry
    }

    /// Registers the key before the Keychain read starts so `clearAll` can invalidate an
    /// in-flight first population even when no display snapshot exists yet.
    private static func beginDisplayRead(key: KeychainCacheStore.Key) -> (DisplaySnapshot?, UInt64) {
        self.displayCacheLock.lock()
        defer { self.displayCacheLock.unlock() }
        let generation = self.displayGenerations[key] ?? 0
        self.displayGenerations[key] = generation
        return (self.displayCache[key], generation)
    }

    private static func scheduleDisplayRevalidation(
        provider: UsageProvider,
        scope: Scope?,
        key: KeychainCacheStore.Key,
        generation: UInt64)
    {
        self.displayCacheLock.lock()
        let inserted = self.displayRevalidationsInFlight.insert(key).inserted
        self.displayCacheLock.unlock()
        guard inserted else { return }
        Task(priority: .utility) {
            self.revalidateDisplaySnapshot(provider: provider, scope: scope, key: key, generation: generation)
        }
    }

    private static func revalidateDisplaySnapshot(
        provider: UsageProvider,
        scope: Scope?,
        key: KeychainCacheStore.Key,
        generation: UInt64)
    {
        switch self.loadOutcome(provider: provider, scope: scope, migrateLegacy: false) {
        case let .authoritative(entry, loadedFromLegacy):
            _ = self.commitDisplaySnapshotIfCurrent(key: key, entry: entry, generation: generation)
            if loadedFromLegacy {
                self.scheduleLegacyMigration(provider: provider)
            }
        case .temporarilyUnavailable:
            self.deferDisplayRetryIfCurrent(key: key, generation: generation)
        }
        self.displayCacheLock.lock()
        self.displayRevalidationsInFlight.remove(key)
        self.displayCacheLock.unlock()
    }

    private static func scheduleLegacyMigration(provider: UsageProvider) {
        self.displayCacheLock.lock()
        let inserted = self.legacyMigrationsInFlight.insert(provider).inserted
        self.displayCacheLock.unlock()
        guard inserted else { return }
        Task(priority: .utility) {
            _ = self.migrateLegacyEntryIfNeeded(provider: provider)
            _ = self.displayCacheLock.withLock {
                self.legacyMigrationsInFlight.remove(provider)
            }
        }
    }

    /// Keychain reads for the display cache happen outside the lock, so a concurrent `store` or
    /// `clear` can publish newer state before the read commits. Each mutation bumps the per-key
    /// generation; a read only commits if the generation it started from is still current, and
    /// otherwise returns whatever newer snapshot won the race.
    private static func commitDisplaySnapshotIfCurrent(
        key: KeychainCacheStore.Key,
        entry: Entry?,
        generation: UInt64) -> Entry?
    {
        self.displayCacheLock.lock()
        defer { self.displayCacheLock.unlock() }
        guard self.displayGenerations[key, default: 0] == generation else {
            return self.displayCache[key]?.entry
        }
        self.displayCache[key] = self.authoritativeDisplaySnapshot(entry: entry)
        return entry
    }

    private static func commitTemporaryDisplaySnapshotIfCurrent(
        key: KeychainCacheStore.Key,
        generation: UInt64) -> Entry?
    {
        self.displayCacheLock.lock()
        defer { self.displayCacheLock.unlock() }
        guard self.displayGenerations[key, default: 0] == generation else {
            return self.displayCache[key]?.entry
        }
        if let current = self.displayCache[key] {
            return current.entry
        }
        self.displayCache[key] = self.temporaryDisplaySnapshot(entry: nil)
        return nil
    }

    private static func deferDisplayRetryIfCurrent(key: KeychainCacheStore.Key, generation: UInt64) {
        self.displayCacheLock.lock()
        defer { self.displayCacheLock.unlock() }
        guard self.displayGenerations[key, default: 0] == generation,
              let current = self.displayCache[key]
        else { return }
        self.displayCache[key] = self.temporaryDisplaySnapshot(entry: current.entry)
    }

    private static func updateDisplaySnapshot(key: KeychainCacheStore.Key, entry: Entry?) {
        self.displayCacheLock.lock()
        self.displayCache[key] = self.authoritativeDisplaySnapshot(entry: entry)
        self.displayGenerations[key, default: 0] += 1
        self.displayCacheLock.unlock()
    }

    private static func invalidateDisplaySnapshot(key: KeychainCacheStore.Key) {
        self.displayCacheLock.lock()
        self.displayCache.removeValue(forKey: key)
        self.displayGenerations[key, default: 0] += 1
        self.displayCacheLock.unlock()
    }

    private static func currentDisplayEntry(key: KeychainCacheStore.Key) -> Entry? {
        self.displayCacheLock.lock()
        defer { self.displayCacheLock.unlock() }
        return self.displayCache[key]?.entry
    }

    private static func authoritativeDisplaySnapshot(entry: Entry?) -> DisplaySnapshot {
        DisplaySnapshot(entry: entry, refreshAfter: Date().addingTimeInterval(self.currentDisplayStalenessInterval))
    }

    private static func temporaryDisplaySnapshot(entry: Entry?) -> DisplaySnapshot {
        DisplaySnapshot(
            entry: entry,
            refreshAfter: Date().addingTimeInterval(self.currentDisplayUnavailableRetryInterval))
    }

    private static var currentDisplayStalenessInterval: TimeInterval {
        self.displayStalenessIntervalOverride ?? self.displayStalenessInterval
    }

    private static var currentDisplayUnavailableRetryInterval: TimeInterval {
        self.displayUnavailableRetryIntervalOverride ?? self.displayUnavailableRetryInterval
    }

    static func setDisplayStalenessIntervalOverrideForTesting(_ interval: TimeInterval?) {
        self.displayStalenessIntervalOverride = interval
    }

    static func setDisplayUnavailableRetryIntervalOverrideForTesting(_ interval: TimeInterval?) {
        self.displayUnavailableRetryIntervalOverride = interval
    }

    static func resetDisplayCacheForTesting() {
        self.displayCacheLock.lock()
        self.displayCache.removeAll()
        self.displayGenerations.removeAll()
        self.displayRevalidationsInFlight.removeAll()
        self.legacyMigrationsInFlight.removeAll()
        self.displayCacheLock.unlock()
    }

    static func beginDisplayReadGenerationForTesting(provider: UsageProvider, scope: Scope? = nil) -> UInt64 {
        self.beginDisplayRead(key: self.key(for: provider, scope: scope)).1
    }

    static func currentDisplayEntryForTesting(provider: UsageProvider, scope: Scope? = nil) -> Entry? {
        self.currentDisplayEntry(key: self.key(for: provider, scope: scope))
    }

    #if DEBUG
    static func withLegacyRemovalFailureForTesting<T>(_ operation: () throws -> T) rethrows -> T {
        try self.$legacyRemovalFailureOverride.withValue(true) {
            try operation()
        }
    }
    #endif

    @discardableResult
    static func commitDisplaySnapshotIfCurrentForTesting(
        provider: UsageProvider,
        scope: Scope? = nil,
        entry: Entry?,
        generation: UInt64) -> Entry?
    {
        self.commitDisplaySnapshotIfCurrent(
            key: self.key(for: provider, scope: scope),
            entry: entry,
            generation: generation)
    }

    public static func load(provider: UsageProvider, scope: Scope? = nil) -> Entry? {
        switch self.loadOutcome(provider: provider, scope: scope, migrateLegacy: true) {
        case let .authoritative(entry, _):
            entry
        case .temporarilyUnavailable:
            nil
        }
    }

    static func loadSerialized(provider: UsageProvider, scope: Scope? = nil) -> Entry? {
        do {
            return try self.withLegacyMutationLock {
                let key = self.key(for: provider, scope: scope)
                switch KeychainCacheStore.load(key: key, as: Entry.self) {
                case let .found(entry):
                    return entry
                case .temporarilyUnavailable:
                    return nil
                case .invalid:
                    KeychainCacheStore.clear(key: key)
                case .missing:
                    break
                }
                guard scope == nil else { return nil }
                return self.migrateLegacyEntryIfNeededLocked(provider: provider)
            }
        } catch {
            self.log.error("Cookie cache serialized load failed: \(error)")
            return nil
        }
    }

    private static func loadOutcome(
        provider: UsageProvider,
        scope: Scope?,
        migrateLegacy: Bool) -> LoadOutcome
    {
        let key = self.key(for: provider, scope: scope)
        switch KeychainCacheStore.load(key: key, as: Entry.self) {
        case let .found(entry):
            self.log.debug("Cookie cache hit", metadata: ["provider": provider.rawValue])
            return .authoritative(entry, loadedFromLegacy: false)
        case .temporarilyUnavailable:
            self.log.debug("Cookie cache temporarily unavailable", metadata: ["provider": provider.rawValue])
            return .temporarilyUnavailable
        case .invalid:
            self.log.warning("Cookie cache invalid; clearing", metadata: ["provider": provider.rawValue])
            KeychainCacheStore.clear(key: key)
        case .missing:
            self.log.debug("Cookie cache miss", metadata: ["provider": provider.rawValue])
        }

        guard scope == nil else { return .authoritative(nil, loadedFromLegacy: false) }
        if migrateLegacy {
            return .authoritative(
                self.migrateLegacyEntryIfNeeded(provider: provider),
                loadedFromLegacy: false)
        }
        guard let legacy = self.loadLegacyEntry(for: provider) else {
            return .authoritative(nil, loadedFromLegacy: false)
        }
        return .authoritative(legacy, loadedFromLegacy: true)
    }

    /// Re-reads both stores while serialized with global cookie mutations. A display-triggered
    /// migration may be queued before a clear, so using the captured legacy entry here would
    /// otherwise allow the delayed task to restore credentials the user just removed.
    private static func migrateLegacyEntryIfNeeded(provider: UsageProvider) -> Entry? {
        do {
            return try self.withLegacyMutationLock {
                self.migrateLegacyEntryIfNeededLocked(provider: provider)
            }
        } catch {
            self.log.error("Cookie cache migration lock failed: \(error)")
            return nil
        }
    }

    private static func migrateLegacyEntryIfNeededLocked(provider: UsageProvider) -> Entry? {
        let key = self.key(for: provider, scope: nil)
        switch KeychainCacheStore.load(key: key, as: Entry.self) {
        case let .found(entry):
            _ = self.removeLegacyEntry(for: provider)
            return entry
        case .temporarilyUnavailable:
            return nil
        case .invalid:
            KeychainCacheStore.clear(key: key)
        case .missing:
            break
        }

        guard let legacy = self.loadLegacyEntry(for: provider) else { return nil }
        if KeychainCacheStore.storeResult(key: key, entry: legacy),
           self.removeLegacyEntry(for: provider) == .removed
        {
            self.log.debug("Cookie cache migrated from legacy store", metadata: ["provider": provider.rawValue])
        }
        return legacy
    }

    public static func store(
        provider: UsageProvider,
        scope: Scope? = nil,
        cookieHeader: String,
        sourceLabel: String,
        now: Date = Date())
    {
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = CookieHeaderNormalizer.normalize(trimmed), !normalized.isEmpty else {
            self.clear(provider: provider, scope: scope)
            return
        }
        let entry = Entry(cookieHeader: normalized, storedAt: now, sourceLabel: sourceLabel)
        do {
            try self.withLegacyMutationLock {
                self.store(entry: entry, provider: provider, scope: scope, sourceLabel: sourceLabel)
            }
        } catch {
            self.log.error("Cookie cache store lock failed: \(error)")
        }
    }

    private static func store(
        entry: Entry,
        provider: UsageProvider,
        scope: Scope?,
        sourceLabel: String)
    {
        let key = self.key(for: provider, scope: scope)
        guard KeychainCacheStore.storeResult(key: key, entry: entry) else { return }
        self.updateDisplaySnapshot(key: key, entry: entry)
        if scope == nil {
            _ = self.removeLegacyEntry(for: provider)
        }
        self.log.debug("Cookie cache stored", metadata: ["provider": provider.rawValue, "source": sourceLabel])
    }

    @discardableResult
    public static func clear(provider: UsageProvider, scope: Scope? = nil) -> Int {
        self.clearDetailed(provider: provider, scope: scope).clearedCount
    }

    public static func clearDetailed(provider: UsageProvider, scope: Scope? = nil) -> ClearSummary {
        do {
            return try self.withLegacyMutationLock {
                self.clearDetailedLocked(provider: provider, scope: scope)
            }
        } catch {
            self.log.error("Cookie cache clear lock failed: \(error)")
            return ClearSummary(clearedCount: 0, failedCount: 1)
        }
    }

    private static func clearDetailedLocked(provider: UsageProvider, scope: Scope?) -> ClearSummary {
        let key = self.key(for: provider, scope: scope)
        let result = KeychainCacheStore.clearResult(key: key)
        var cleared = result == .removed ? 1 : 0
        var failed = result == .failed ? 1 : 0
        if result != .failed {
            self.updateDisplaySnapshot(key: key, entry: nil)
        }
        let legacyResult: LegacyRemovalResult = if scope == nil {
            self.removeLegacyEntry(for: provider)
        } else {
            .missing
        }
        if legacyResult == .removed {
            cleared += 1
            if result == .failed {
                self.invalidateDisplaySnapshot(key: key)
            }
        } else if legacyResult == .failed {
            failed += 1
        }
        self.log.debug("Cookie cache cleared", metadata: ["provider": provider.rawValue])
        return ClearSummary(clearedCount: cleared, failedCount: failed)
    }

    /// Clears all cookie cache scopes for one provider, including managed Codex account scopes.
    /// Returns keychain/legacy removal and failure counts.
    @discardableResult
    public static func clearAllScopes(provider: UsageProvider) -> Int {
        self.clearAllScopesDetailed(provider: provider).clearedCount
    }

    public static func clearAllScopesDetailed(provider: UsageProvider) -> ClearSummary {
        do {
            return try self.withLegacyMutationLock {
                self.clearAllScopesDetailedLocked(provider: provider)
            }
        } catch {
            self.log.error("Cookie cache clearAllScopes lock failed: \(error)")
            return ClearSummary(clearedCount: 0, failedCount: 1)
        }
    }

    private static func clearAllScopesDetailedLocked(provider: UsageProvider) -> ClearSummary {
        let (keys, enumerationFailed) = self.cookieKeysResult(for: provider)
        var cleared = 0
        var failedKeys = Set<KeychainCacheStore.Key>()
        for key in keys {
            let result = KeychainCacheStore.clearResult(key: key)
            if result == .removed {
                cleared += 1
            }
            if result != .failed {
                self.updateDisplaySnapshot(key: key, entry: nil)
            } else {
                failedKeys.insert(key)
            }
        }
        let legacyResult = self.removeLegacyEntry(for: provider)
        if legacyResult == .removed {
            cleared += 1
            let globalKey = self.key(for: provider, scope: nil)
            if failedKeys.contains(globalKey) {
                self.invalidateDisplaySnapshot(key: globalKey)
            }
        }
        let failedCount = failedKeys.count + (enumerationFailed ? 1 : 0) + (legacyResult == .failed ? 1 : 0)
        self.log.debug("Cookie cache clearAllScopes completed", metadata: [
            "provider": provider.rawValue,
            "cleared": "\(cleared)",
        ])
        return ClearSummary(clearedCount: cleared, failedCount: failedCount)
    }

    /// Clears cookie caches for all providers, including corrupt/invalid entries.
    /// Returns keychain/legacy removal and failure counts.
    @discardableResult
    public static func clearAll() -> Int {
        self.clearAllDetailed().clearedCount
    }

    public static func clearAllDetailed() -> ClearSummary {
        do {
            return try self.withLegacyMutationLock {
                self.clearAllDetailedLocked()
            }
        } catch {
            self.log.error("Cookie cache clearAll lock failed: \(error)")
            return ClearSummary(clearedCount: 0, failedCount: 1)
        }
    }

    private static func clearAllDetailedLocked() -> ClearSummary {
        self.displayCacheLock.lock()
        let knownDisplayKeys = Set(self.displayCache.keys).union(self.displayGenerations.keys)
        self.displayCacheLock.unlock()
        let enumeratedKeys: [KeychainCacheStore.Key]
        let enumerationFailed: Bool
        switch KeychainCacheStore.keysResult(category: "cookie") {
        case let .found(keys):
            enumeratedKeys = keys
            enumerationFailed = false
        case .temporarilyUnavailable, .failed:
            enumeratedKeys = []
            enumerationFailed = true
        }
        let keys = Set(enumeratedKeys).union(knownDisplayKeys)
        var cleared = 0
        var failedKeys = Set<KeychainCacheStore.Key>()
        for key in keys {
            let result = KeychainCacheStore.clearResult(key: key)
            if result == .removed {
                cleared += 1
            }
            if result != .failed {
                self.updateDisplaySnapshot(key: key, entry: nil)
            } else {
                failedKeys.insert(key)
            }
        }
        var legacyFailures = 0
        for provider in UsageProvider.allCases {
            switch self.removeLegacyEntry(for: provider) {
            case .removed:
                cleared += 1
                let globalKey = self.key(for: provider, scope: nil)
                if failedKeys.contains(globalKey) {
                    self.invalidateDisplaySnapshot(key: globalKey)
                }
            case .failed:
                legacyFailures += 1
            case .missing:
                break
            }
        }
        self.log.debug("Cookie cache clearAll completed", metadata: ["cleared": "\(cleared)"])
        return ClearSummary(
            clearedCount: cleared,
            failedCount: failedKeys.count + (enumerationFailed ? 1 : 0) + legacyFailures)
    }

    private static func cookieKeysResult(for provider: UsageProvider) -> ([KeychainCacheStore.Key], Bool) {
        let exactIdentifier = provider.rawValue
        let scopedPrefix = "\(provider.rawValue)."
        var seen = Set<KeychainCacheStore.Key>()
        var keys: [KeychainCacheStore.Key] = []
        let enumeratedKeys: [KeychainCacheStore.Key]
        let enumerationFailed: Bool
        switch KeychainCacheStore.keysResult(category: "cookie") {
        case let .found(keys):
            enumeratedKeys = keys
            enumerationFailed = false
        case .temporarilyUnavailable, .failed:
            enumeratedKeys = []
            enumerationFailed = true
        }
        for key in enumeratedKeys {
            guard key.identifier == exactIdentifier || key.identifier.hasPrefix(scopedPrefix) else {
                continue
            }
            if seen.insert(key).inserted {
                keys.append(key)
            }
        }
        let global = self.key(for: provider, scope: nil)
        if seen.insert(global).inserted {
            keys.append(global)
        }
        return (keys, enumerationFailed)
    }

    static func load(from url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Entry.self, from: data)
    }

    static func store(_ entry: Entry, to url: URL) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entry)
            try data.write(to: url, options: [.atomic])
        } catch {
            self.log.error("Failed to persist cookie cache: \(error)")
        }
    }

    static func setLegacyBaseURLOverrideForTesting(_ url: URL?) {
        self.legacyBaseURLOverrideLock.withLock {
            self.legacyBaseURLOverride = url
        }
    }

    static func hasLegacyEntryForTesting(provider: UsageProvider) -> Bool {
        self.loadLegacyEntry(for: provider) != nil
    }

    static func legacyURLForTesting(provider: UsageProvider) -> URL {
        self.legacyURL(for: provider)
    }

    private static func hasKeychainEntry(provider: UsageProvider, scope: Scope?) -> Bool {
        let key = self.key(for: provider, scope: scope)
        switch KeychainCacheStore.load(key: key, as: Entry.self) {
        case .found, .invalid:
            return true
        case .missing, .temporarilyUnavailable:
            return false
        }
    }

    static func hasKeychainEntryForTesting(provider: UsageProvider, scope: Scope? = nil) -> Bool {
        self.hasKeychainEntry(provider: provider, scope: scope)
    }

    static func migrateLegacyEntryIfNeededForTesting(provider: UsageProvider) -> Entry? {
        self.migrateLegacyEntryIfNeeded(provider: provider)
    }

    private static func withLegacyMutationLock<T>(_ operation: () throws -> T) throws -> T {
        try self.legacyMutationLock.withLock {
            let lockURL = self.legacyMutationLockURL
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer {
                _ = flock(fd, LOCK_UN)
                close(fd)
            }
            while flock(fd, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return try operation()
        }
    }

    private static var legacyMutationLockURL: URL {
        let base = self.currentLegacyBaseURLOverride ?? self.defaultLegacyBaseURL
        return base.appendingPathComponent("cookie-cache.lock")
    }

    private static func removeLegacyEntry(for provider: UsageProvider) -> LegacyRemovalResult {
        let url = self.legacyURL(for: provider)
        #if DEBUG
        if self.legacyRemovalFailureOverride {
            return .failed
        }
        #endif
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            try FileManager.default.removeItem(at: url)
            return existed ? .removed : .missing
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                Self.log.error("Failed to remove cookie cache (\(provider.rawValue)): \(error)")
                return .failed
            }
            return .missing
        }
    }

    private static func loadLegacyEntry(for provider: UsageProvider) -> Entry? {
        self.load(from: self.legacyURL(for: provider))
    }

    private static func legacyURL(for provider: UsageProvider) -> URL {
        if let override = self.currentLegacyBaseURLOverride {
            return override.appendingPathComponent("\(provider.rawValue)-cookie.json")
        }
        return self.defaultLegacyBaseURL.appendingPathComponent("\(provider.rawValue)-cookie.json")
    }

    private static var currentLegacyBaseURLOverride: URL? {
        self.legacyBaseURLOverrideLock.withLock {
            self.legacyBaseURLOverride
        }
    }

    private static var defaultLegacyBaseURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("CodexBar", isDirectory: true)
    }

    private static func key(for provider: UsageProvider, scope: Scope?) -> KeychainCacheStore.Key {
        KeychainCacheStore.Key.cookie(provider: provider, scopeIdentifier: scope?.keychainIdentifier)
    }
}
