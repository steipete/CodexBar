import Foundation

public enum CookieHeaderCache {
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

    public static func load(provider: UsageProvider) -> Entry? {
        let key = KeychainCacheStore.Key.cookie(provider: provider)
        switch KeychainCacheStore.load(key: key, as: Entry.self) {
        case let .found(entry):
            self.log.debug("Cookie cache hit", metadata: ["provider": provider.rawValue])
            return entry
        case .invalid:
            self.log.warning("Cookie cache invalid; clearing", metadata: ["provider": provider.rawValue])
            KeychainCacheStore.clear(key: key)
        case .missing:
            self.log.debug("Cookie cache miss", metadata: ["provider": provider.rawValue])
        }

        guard let legacy = self.loadLegacyEntry(for: provider) else { return nil }
        KeychainCacheStore.store(key: key, entry: legacy)
        self.removeLegacyEntry(for: provider)
        self.log.debug("Cookie cache migrated from legacy store", metadata: ["provider": provider.rawValue])
        return legacy
    }

    public static func store(
        provider: UsageProvider,
        cookieHeader: String,
        sourceLabel: String,
        now: Date = Date())
    {
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = CookieHeaderNormalizer.normalize(trimmed), !normalized.isEmpty else {
            self.clear(provider: provider)
            return
        }
        let entry = Entry(cookieHeader: normalized, storedAt: now, sourceLabel: sourceLabel)
        let key = KeychainCacheStore.Key.cookie(provider: provider)
        KeychainCacheStore.store(key: key, entry: entry)
        self.removeLegacyEntry(for: provider)
        self.log.debug("Cookie cache stored", metadata: ["provider": provider.rawValue, "source": sourceLabel])
    }

    public static func clear(provider: UsageProvider) {
        let key = KeychainCacheStore.Key.cookie(provider: provider)
        KeychainCacheStore.clear(key: key)
        self.removeLegacyEntry(for: provider)
        self.log.debug("Cookie cache cleared", metadata: ["provider": provider.rawValue])
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

    private static func loadLegacyEntry(for provider: UsageProvider) -> Entry? {
        self.load(from: self.legacyURL(for: provider))
    }

    private static func removeLegacyEntry(for provider: UsageProvider) {
        let url = self.legacyURL(for: provider)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                Self.log.error("Failed to remove cookie cache (\(provider.rawValue)): \(error)")
            }
        }
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
}
