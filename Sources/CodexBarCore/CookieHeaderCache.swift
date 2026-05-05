import Foundation

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

    private static let log = CodexBarLog.logger(LogCategories.cookieCache)
    private nonisolated(unsafe) static var legacyBaseURLOverride: URL?

    public static func load(provider: UsageProvider, scope: Scope? = nil) -> Entry? {
        let key = self.key(for: provider, scope: scope)
        switch KeychainCacheStore.load(key: key, as: Entry.self) {
        case let .found(entry):
            self.log.debug("Cookie cache hit", metadata: ["provider": provider.rawValue])
            return entry
        case .temporarilyUnavailable:
            self.log.debug("Cookie cache temporarily unavailable", metadata: ["provider": provider.rawValue])
            return nil
        case .invalid:
            self.log.warning("Cookie cache invalid; clearing", metadata: ["provider": provider.rawValue])
            KeychainCacheStore.clear(key: key)
        case .missing:
            self.log.debug("Cookie cache miss", metadata: ["provider": provider.rawValue])
        }

        guard scope == nil else { return nil }
        guard let legacy = self.loadLegacyEntry(for: provider) else { return nil }
        KeychainCacheStore.store(key: key, entry: legacy)
        self.removeLegacyEntry(for: provider)
        self.log.debug("Cookie cache migrated from legacy store", metadata: ["provider": provider.rawValue])
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
        let key = self.key(for: provider, scope: scope)
        KeychainCacheStore.store(key: key, entry: entry)
        if scope == nil {
            self.removeLegacyEntry(for: provider)
        }
        self.log.debug("Cookie cache stored", metadata: ["provider": provider.rawValue, "source": sourceLabel])
    }

    @discardableResult
    public static func clear(provider: UsageProvider, scope: Scope? = nil) -> Int {
        let key = self.key(for: provider, scope: scope)
        var cleared = KeychainCacheStore.clear(key: key) ? 1 : 0
        if scope == nil, self.removeLegacyEntry(for: provider) {
            cleared += 1
        }
        self.log.debug("Cookie cache cleared", metadata: ["provider": provider.rawValue])
        return cleared
    }

    /// Clears all cookie cache scopes for one provider, including managed Codex account scopes.
    /// Returns the number of keychain or legacy-file entries removed.
    @discardableResult
    public static func clearAllScopes(provider: UsageProvider) -> Int {
        let keys = self.cookieKeys(for: provider)
        var cleared = 0
        for key in keys where KeychainCacheStore.clear(key: key) {
            cleared += 1
        }
        if self.removeLegacyEntry(for: provider) {
            cleared += 1
        }
        self.log.debug("Cookie cache clearAllScopes completed", metadata: [
            "provider": provider.rawValue,
            "cleared": "\(cleared)",
        ])
        return cleared
    }

    /// Clears cookie caches for all providers, including corrupt/invalid entries.
    /// Returns the number of keychain or legacy-file entries removed.
    @discardableResult
    public static func clearAll() -> Int {
        var cleared = 0
        for key in KeychainCacheStore.keys(category: "cookie") where KeychainCacheStore.clear(key: key) {
            cleared += 1
        }
        for provider in UsageProvider.allCases where self.removeLegacyEntry(for: provider) {
            cleared += 1
        }
        self.log.debug("Cookie cache clearAll completed", metadata: ["cleared": "\(cleared)"])
        return cleared
    }

    private static func cookieKeys(for provider: UsageProvider) -> [KeychainCacheStore.Key] {
        let exactIdentifier = provider.rawValue
        let scopedPrefix = "\(provider.rawValue)."
        var seen = Set<KeychainCacheStore.Key>()
        var keys: [KeychainCacheStore.Key] = []
        for key in KeychainCacheStore.keys(category: "cookie") {
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
        return keys
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
        self.legacyBaseURLOverride = url
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

    @discardableResult
    private static func removeLegacyEntry(for provider: UsageProvider) -> Bool {
        let url = self.legacyURL(for: provider)
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            try FileManager.default.removeItem(at: url)
            return existed
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                Self.log.error("Failed to remove cookie cache (\(provider.rawValue)): \(error)")
            }
            return false
        }
    }

    private static func loadLegacyEntry(for provider: UsageProvider) -> Entry? {
        self.load(from: self.legacyURL(for: provider))
    }

    private static func legacyURL(for provider: UsageProvider) -> URL {
        if let override = self.legacyBaseURLOverride {
            return override.appendingPathComponent("\(provider.rawValue)-cookie.json")
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-cookie.json")
    }

    private static func key(for provider: UsageProvider, scope: Scope?) -> KeychainCacheStore.Key {
        KeychainCacheStore.Key.cookie(provider: provider, scopeIdentifier: scope?.keychainIdentifier)
    }
}
