import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CLIProxyAPIUsageRecord: Codable, Equatable, Sendable {
    struct Tokens: Codable, Equatable, Sendable {
        let input: Int
        let output: Int
        let reasoning: Int
        let cached: Int
        let cacheRead: Int
        let cacheCreation: Int
        let total: Int

        private enum CodingKeys: String, CodingKey {
            case input = "input_tokens"
            case output = "output_tokens"
            case reasoning = "reasoning_tokens"
            case cached = "cached_tokens"
            case cacheRead = "cache_read_tokens"
            case cacheCreation = "cache_creation_tokens"
            case total = "total_tokens"
        }

        init(
            input: Int,
            output: Int,
            reasoning: Int = 0,
            cached: Int = 0,
            cacheRead: Int = 0,
            cacheCreation: Int = 0,
            total: Int)
        {
            self.input = input
            self.output = output
            self.reasoning = reasoning
            self.cached = cached
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
            self.total = total
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
            self.output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
            self.reasoning = try container.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
            self.cached = try container.decodeIfPresent(Int.self, forKey: .cached) ?? 0
            self.cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
            self.cacheCreation = try container.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0
            self.total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        }
    }

    let timestamp: Date
    let provider: String
    let executorType: String?
    let model: String
    let alias: String
    let endpoint: String
    let authType: String
    let requestID: String
    let localOccurrenceID: String?
    let failed: Bool
    let generate: Bool
    let tokens: Tokens

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case provider
        case executorType = "executor_type"
        case model
        case alias
        case endpoint
        case authType = "auth_type"
        case requestID = "request_id"
        case localOccurrenceID = "codexbar_occurrence_id"
        case failed
        case generate
        case tokens
    }

    init(
        timestamp: Date,
        provider: String,
        executorType: String? = nil,
        model: String,
        alias: String,
        endpoint: String,
        authType: String,
        requestID: String,
        localOccurrenceID: String? = nil,
        failed: Bool = false,
        generate: Bool = true,
        tokens: Tokens)
    {
        self.timestamp = timestamp
        self.provider = provider
        self.executorType = executorType
        self.model = model
        self.alias = alias
        self.endpoint = endpoint
        self.authType = authType
        self.requestID = requestID
        self.localOccurrenceID = localOccurrenceID
        self.failed = failed
        self.generate = generate
        self.tokens = tokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.executorType = try container.decodeIfPresent(String.self, forKey: .executorType)
        self.model = try container.decode(String.self, forKey: .model)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? self.model
        self.endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        self.authType = try container.decodeIfPresent(String.self, forKey: .authType) ?? ""
        self.requestID = try container.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        self.localOccurrenceID = try container.decodeIfPresent(String.self, forKey: .localOccurrenceID)
        self.failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        self.generate = try container.decodeIfPresent(Bool.self, forKey: .generate) ?? true
        self.tokens = try container.decodeIfPresent(Tokens.self, forKey: .tokens)
            ?? Tokens(input: 0, output: 0, total: 0)
    }

    func assigningNewLocalOccurrenceID() -> Self {
        guard self.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        return Self(
            timestamp: self.timestamp,
            provider: self.provider,
            executorType: self.executorType,
            model: self.model,
            alias: self.alias,
            endpoint: self.endpoint,
            authType: self.authType,
            requestID: self.requestID,
            localOccurrenceID: UUID().uuidString.lowercased(),
            failed: self.failed,
            generate: self.generate,
            tokens: self.tokens)
    }

    func replacingTimestamp(_ timestamp: Date) -> Self {
        Self(
            timestamp: timestamp,
            provider: self.provider,
            executorType: self.executorType,
            model: self.model,
            alias: self.alias,
            endpoint: self.endpoint,
            authType: self.authType,
            requestID: self.requestID,
            localOccurrenceID: self.localOccurrenceID,
            failed: self.failed,
            generate: self.generate,
            tokens: self.tokens)
    }
}

private enum CLIProxyAPIUsageRetention {
    private static let maximumRecordAge: TimeInterval = 366 * 24 * 60 * 60
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60

    static func normalize(
        _ records: [CLIProxyAPIUsageRecord],
        now: Date) -> [CLIProxyAPIUsageRecord]
    {
        let cutoff = now.addingTimeInterval(-self.maximumRecordAge)
        let futureCutoff = now.addingTimeInterval(self.maximumFutureClockSkew)
        return records.compactMap { record in
            guard record.timestamp >= cutoff, record.timestamp <= futureCutoff else { return nil }
            return record.timestamp > now ? record.replacingTimestamp(now) : record
        }
    }
}

enum CLIProxyAPIUsageCacheIO {
    private struct Cache: Codable, Equatable {
        var version: Int = 1
        var records: [CLIProxyAPIUsageRecord] = []
    }

    private enum CacheReadResult {
        case missing
        case valid(Cache)
        case invalid
    }

    private static let cacheLock = NSLock()

    static func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        try self.cacheLock.withLock(body)
    }

    static func pruneUnserialized(
        cacheRoot: URL?,
        now: Date) -> Bool
    {
        let legacyCacheRoot = cacheRoot == nil ? self.defaultLegacyCacheRoot() : nil
        return self.withExclusiveAccess {
            guard let currentCache = self.loadCache(
                cacheRoot: cacheRoot,
                legacyCacheRoot: legacyCacheRoot)
            else { return false }
            let retainedCache = Cache(records: CLIProxyAPIUsageRetention.normalize(currentCache.records, now: now))
            return retainedCache == currentCache || self.save(retainedCache, cacheRoot: cacheRoot)
        }
    }

    static func load(
        cacheRoot: URL? = nil,
        now: Date = Date()) -> [CLIProxyAPIUsageRecord]
    {
        let legacyCacheRoot = cacheRoot == nil ? self.defaultLegacyCacheRoot() : nil
        return self.load(
            cacheRoot: cacheRoot,
            legacyCacheRoot: legacyCacheRoot,
            now: now)
    }

    /// Reads and prunes the cache while the caller already owns the CLIProxyAPI interprocess lock.
    static func loadAssumingInterprocessLockHeld(
        cacheRoot: URL?,
        now: Date = Date()) -> [CLIProxyAPIUsageRecord]
    {
        let legacyCacheRoot = cacheRoot == nil ? self.defaultLegacyCacheRoot() : nil
        return self.withExclusiveAccess {
            guard let currentCache = self.loadCache(
                cacheRoot: cacheRoot,
                legacyCacheRoot: legacyCacheRoot)
            else { return [] }
            let retainedRecords = CLIProxyAPIUsageRetention.normalize(currentCache.records, now: now)
            let retainedCache = Cache(records: retainedRecords)
            if retainedCache != currentCache {
                _ = self.save(retainedCache, cacheRoot: cacheRoot)
            }
            return retainedRecords
        }
    }

    static func load(
        cacheRoot: URL?,
        legacyCacheRoot: URL?,
        now: Date = Date()) -> [CLIProxyAPIUsageRecord]
    {
        if self.hasLegacyCacheToMigrate(
            cacheRoot: cacheRoot,
            legacyCacheRoot: legacyCacheRoot)
        {
            do {
                return try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                    stateRoot: cacheRoot?.deletingLastPathComponent())
                {
                    self.withExclusiveAccess {
                        guard let currentCache = self.loadCache(
                            cacheRoot: cacheRoot,
                            legacyCacheRoot: legacyCacheRoot)
                        else { return [] }
                        let retainedRecords = CLIProxyAPIUsageRetention.normalize(currentCache.records, now: now)
                        let retainedCache = Cache(records: retainedRecords)
                        if retainedCache != currentCache {
                            _ = self.save(retainedCache, cacheRoot: cacheRoot)
                        }
                        return retainedRecords
                    }
                }
            } catch {
                return self.withExclusiveAccess {
                    self.loadCache(
                        cacheRoot: cacheRoot,
                        legacyCacheRoot: nil).map { CLIProxyAPIUsageRetention.normalize($0.records, now: now) } ?? []
                }
            }
        }

        let initialSnapshot: (records: [CLIProxyAPIUsageRecord], needsPruning: Bool) = self.withExclusiveAccess {
            guard let existingCache = self.loadCache(
                cacheRoot: cacheRoot,
                legacyCacheRoot: nil)
            else { return ([], false) }
            let retainedRecords = CLIProxyAPIUsageRetention.normalize(existingCache.records, now: now)
            return (retainedRecords, retainedRecords != existingCache.records)
        }
        guard initialSnapshot.needsPruning else { return initialSnapshot.records }

        do {
            return try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                stateRoot: cacheRoot?.deletingLastPathComponent())
            {
                self.withExclusiveAccess {
                    guard let currentCache = self.loadCache(
                        cacheRoot: cacheRoot,
                        legacyCacheRoot: nil)
                    else { return [] }
                    let retainedRecords = CLIProxyAPIUsageRetention.normalize(currentCache.records, now: now)
                    let retainedCache = Cache(records: retainedRecords)
                    if retainedCache != currentCache {
                        _ = self.save(retainedCache, cacheRoot: cacheRoot)
                    }
                    return retainedRecords
                }
            }
        } catch {
            return initialSnapshot.records
        }
    }

    @discardableResult
    static func merge(
        _ records: [CLIProxyAPIUsageRecord],
        cacheRoot: URL? = nil,
        now: Date = Date()) -> Int?
    {
        let legacyCacheRoot = cacheRoot == nil ? self.defaultLegacyCacheRoot() : nil
        return self.merge(
            records,
            cacheRoot: cacheRoot,
            legacyCacheRoot: legacyCacheRoot,
            now: now)
    }

    @discardableResult
    static func merge(
        _ records: [CLIProxyAPIUsageRecord],
        cacheRoot: URL?,
        legacyCacheRoot: URL?,
        now: Date = Date()) -> Int?
    {
        self.withExclusiveAccess {
            guard let existingCache = self.loadCache(
                cacheRoot: cacheRoot,
                legacyCacheRoot: legacyCacheRoot)
            else { return nil }
            var byKey = self.recordsByKey(CLIProxyAPIUsageRetention.normalize(existingCache.records, now: now))
            let priorCount = byKey.count
            for (key, record) in self.recordsByKey(CLIProxyAPIUsageRetention.normalize(records, now: now)) {
                byKey[key] = record
            }
            let cache = Cache(records: byKey.values.sorted { $0.timestamp < $1.timestamp })
            if cache == existingCache {
                return 0
            }
            guard self.save(cache, cacheRoot: cacheRoot) else { return nil }
            return max(0, byKey.count - priorCount)
        }
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName, isDirectory: false)
    }

    static func revision(
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default) -> String?
    {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate.bitPattern ?? 0
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(fileNumber):\(modificationDate):\(fileSize)"
    }

    static func legacyCacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultLegacyCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName, isDirectory: false)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = CostUsageDateParser.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid CLIProxyAPI usage timestamp.")
            }
            return date
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func recordKey(_ record: CLIProxyAPIUsageRecord) -> String {
        let requestID = record.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestID.isEmpty {
            return "request:\(requestID)"
        }
        let localOccurrenceID = record.localOccurrenceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !localOccurrenceID.isEmpty {
            return "occurrence:\(localOccurrenceID)"
        }
        let timestamp = Int64(record.timestamp.timeIntervalSince1970 * 1000)
        return [
            "fallback",
            String(timestamp),
            record.provider,
            record.model,
            record.alias,
            record.endpoint,
            record.authType,
            String(record.tokens.input),
            String(record.tokens.cacheRead),
            String(record.tokens.cacheCreation),
            String(record.tokens.output),
        ].joined(separator: ":")
    }

    private static func recordsByKey(
        _ records: [CLIProxyAPIUsageRecord]) -> [String: CLIProxyAPIUsageRecord]
    {
        var fallbackOccurrences: [String: Int] = [:]
        var recordsByKey: [String: CLIProxyAPIUsageRecord] = [:]
        for record in records {
            let baseKey = self.recordKey(record)
            let requestID = record.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
            let localOccurrenceID = record.localOccurrenceID?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !requestID.isEmpty || !localOccurrenceID.isEmpty {
                recordsByKey[baseKey] = record
                continue
            }
            let occurrence = fallbackOccurrences[baseKey, default: 0]
            fallbackOccurrences[baseKey] = occurrence + 1
            recordsByKey["\(baseKey):occurrence:\(occurrence)"] = record
        }
        return recordsByKey
    }

    private static func defaultLegacyCacheRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
    }

    private static func hasLegacyCacheToMigrate(
        cacheRoot: URL?,
        legacyCacheRoot: URL?,
        fileManager: FileManager = .default) -> Bool
    {
        guard let legacyCacheRoot else { return false }
        let durableURL = self.cacheFileURL(cacheRoot: cacheRoot)
        let legacyURL = self.legacyCacheFileURL(cacheRoot: legacyCacheRoot)
        return legacyURL.standardizedFileURL != durableURL.standardizedFileURL
            && fileManager.fileExists(atPath: legacyURL.path)
    }

    private static func loadCache(cacheRoot: URL?, legacyCacheRoot: URL?) -> Cache? {
        let durableURL = self.cacheFileURL(cacheRoot: cacheRoot)
        let durableCache: Cache?
        switch self.readCache(at: durableURL) {
        case .missing:
            durableCache = nil
        case let .valid(cache):
            durableCache = cache
        case .invalid:
            return nil
        }
        guard let legacyCacheRoot else { return durableCache ?? Cache() }

        let legacyURL = self.legacyCacheFileURL(cacheRoot: legacyCacheRoot)
        guard legacyURL.standardizedFileURL != durableURL.standardizedFileURL else {
            return durableCache ?? Cache()
        }
        let legacyCache: Cache
        switch self.readCache(at: legacyURL) {
        case let .valid(cache):
            legacyCache = cache
        case .missing, .invalid:
            return durableCache ?? Cache()
        }

        let migratedCache = self.mergedCaches(legacy: legacyCache, durable: durableCache)
        if self.save(migratedCache, cacheRoot: cacheRoot) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        return migratedCache
    }

    private static func readCache(at url: URL, fileManager: FileManager = .default) -> CacheReadResult {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let cache = try? self.decoder.decode(Cache.self, from: data),
              cache.version == 1
        else { return .invalid }
        return .valid(cache)
    }

    private static func mergedCaches(legacy: Cache, durable: Cache?) -> Cache {
        var byKey = self.recordsByKey(legacy.records)
        for (key, record) in self.recordsByKey(durable?.records ?? []) {
            byKey[key] = record
        }
        return Cache(records: byKey.values.sorted { $0.timestamp < $1.timestamp })
    }

    private static func save(_ cache: Cache, cacheRoot: URL?) -> Bool {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try self.encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}

package enum CLIProxyAPIUsageTelemetryRevision {
    package static func current(
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default) -> String?
    {
        CLIProxyAPIUsageCacheIO.revision(cacheRoot: cacheRoot, fileManager: fileManager)
    }
}

enum CLIProxyAPIUsagePendingIO {
    private struct PendingBatch: Codable {
        var version: Int = 1
        var records: [CLIProxyAPIUsageRecord] = []
    }

    static func load(
        pendingRoot: URL? = nil,
        now: Date = Date()) -> [CLIProxyAPIUsageRecord]?
    {
        let url = self.pendingFileURL(pendingRoot: pendingRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let pendingBatch = try? self.decoder.decode(PendingBatch.self, from: data),
              pendingBatch.version == 1
        else { return nil }
        let retainedRecords = CLIProxyAPIUsageRetention.normalize(pendingBatch.records, now: now)
        if retainedRecords != pendingBatch.records {
            guard retainedRecords.isEmpty
                ? self.clear(pendingRoot: pendingRoot)
                : self.save(retainedRecords, pendingRoot: pendingRoot)
            else { return nil }
        }
        return retainedRecords
    }

    static func save(_ records: [CLIProxyAPIUsageRecord], pendingRoot: URL? = nil) -> Bool {
        let url = self.pendingFileURL(pendingRoot: pendingRoot)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try self.encoder.encode(PendingBatch(records: records))
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func clear(pendingRoot: URL? = nil) -> Bool {
        let url = self.pendingFileURL(pendingRoot: pendingRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    static func pendingFileURL(pendingRoot: URL? = nil) -> URL {
        let root = pendingRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(CostUsageCacheLocations.cliProxyAPIPendingFileName, isDirectory: false)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = CostUsageDateParser.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid pending CLIProxyAPI usage timestamp.")
            }
            return date
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

public struct CLIProxyAPIConnectionSettings: Codable, Equatable, Sendable {
    public static let defaultBaseURL = "http://127.0.0.1:8317"

    public let baseURL: String
    public let managementKey: String

    public init(baseURL: String = Self.defaultBaseURL, managementKey: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.managementKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        !self.managementKey.isEmpty && self.resolvedBaseURL != nil
    }

    var resolvedBaseURL: URL? {
        let value = self.baseURL.isEmpty ? Self.defaultBaseURL : self.baseURL
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              ["127.0.0.1", "::1", "localhost"].contains(host)
        else { return nil }
        return url
    }
}

public enum CLIProxyAPIConnectionSettingsStore {
    enum StoredSettingsSnapshot: Sendable {
        case found(CLIProxyAPIConnectionSettings)
        case missing
        case unavailable
    }

    enum ArtifactDisposition: Equatable, Sendable {
        case preserve
        case purge
    }

    struct SerializedSaveOperations: Sendable {
        let isDisconnected: @Sendable () -> Bool
        let loadStored: @Sendable () -> StoredSettingsSnapshot
        let store: @Sendable (CLIProxyAPIConnectionSettings) -> Bool
        let setDisconnectedState: @Sendable (Bool) -> Bool
        let restore: @Sendable (StoredSettingsSnapshot) -> Bool
    }

    struct SerializedRemovalOperations: Sendable {
        let isDisconnected: @Sendable () -> Bool
        let loadStored: @Sendable () -> StoredSettingsSnapshot
        let clearConfiguration: @Sendable () -> Bool
        let setDisconnectedState: @Sendable (Bool) -> Bool
        let restore: @Sendable (StoredSettingsSnapshot) -> Bool
    }

    struct SerializedRemovalSnapshot: Sendable {
        let wasDisconnected: Bool
        let storedSettings: StoredSettingsSnapshot
    }

    private static let key = KeychainCacheStore.Key(
        category: "integration",
        identifier: "cliproxyapi-management")

    public static func load() -> CLIProxyAPIConnectionSettings? {
        guard case let .found(settings) = self.loadResult() else { return nil }
        return settings
    }

    public static func loadResult() -> KeychainCacheStore.LoadResult<CLIProxyAPIConnectionSettings> {
        self.loadResult(
            isDisconnected: { CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected() },
            loadStored: { KeychainCacheStore.load(key: self.key, as: CLIProxyAPIConnectionSettings.self) })
    }

    static func loadResult(
        isDisconnected: () -> Bool,
        loadStored: () -> KeychainCacheStore.LoadResult<CLIProxyAPIConnectionSettings>)
        -> KeychainCacheStore.LoadResult<CLIProxyAPIConnectionSettings>
    {
        guard !isDisconnected() else { return .missing }
        return loadStored()
    }

    static func load(
        isDisconnected: () -> Bool,
        loadStored: () -> CLIProxyAPIConnectionSettings?) -> CLIProxyAPIConnectionSettings?
    {
        guard !isDisconnected() else { return nil }
        return loadStored()
    }

    @discardableResult
    public static func save(_ settings: CLIProxyAPIConnectionSettings) -> Bool {
        let fileManager = FileManager.default
        let directories = CostUsageCacheLocations.directories(fileManager: fileManager)
        return self.saveSerialized(
            settings,
            artifactDirectories: directories,
            stateRoot: directories[1].deletingLastPathComponent(),
            fileManager: fileManager,
            operations: SerializedSaveOperations(
                isDisconnected: { CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected() },
                loadStored: {
                    self.storedSettingsSnapshot(from: KeychainCacheStore.load(
                        key: self.key,
                        as: CLIProxyAPIConnectionSettings.self))
                },
                store: { KeychainCacheStore.storeResult(key: self.key, entry: $0) },
                setDisconnectedState: { CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected($0) },
                restore: { storedSettings in
                    self.restoreStoredSettings(
                        storedSettings,
                        store: { KeychainCacheStore.storeResult(key: self.key, entry: $0) },
                        clear: { KeychainCacheStore.clearResult(key: self.key) })
                }))
    }

    static func storedSettingsSnapshot(
        from result: KeychainCacheStore.LoadResult<CLIProxyAPIConnectionSettings>) -> StoredSettingsSnapshot
    {
        switch result {
        case let .found(settings): .found(settings)
        case .missing: .missing
        case .temporarilyUnavailable, .invalid: .unavailable
        }
    }

    static func restoreStoredSettings(
        _ storedSettings: StoredSettingsSnapshot,
        store: (CLIProxyAPIConnectionSettings) -> Bool,
        clear: () -> KeychainCacheStore.ClearResult) -> Bool
    {
        switch storedSettings {
        case let .found(previousSettings):
            store(previousSettings)
        case .missing:
            switch clear() {
            case .removed, .missing: true
            case .failed: false
            }
        case .unavailable:
            false
        }
    }

    static func artifactDisposition(
        _ settings: CLIProxyAPIConnectionSettings,
        isDisconnected: Bool,
        storedSettings: StoredSettingsSnapshot) -> ArtifactDisposition?
    {
        switch storedSettings {
        case let .found(currentSettings):
            if !isDisconnected, currentSettings == settings {
                return .preserve
            }
            return .purge
        case .missing:
            return .purge
        case .unavailable:
            return nil
        }
    }

    static func saveSerialized(
        _ settings: CLIProxyAPIConnectionSettings,
        artifactDirectories: [URL] = [],
        stateRoot: URL?,
        fileManager: FileManager,
        operations: SerializedSaveOperations) -> Bool
    {
        guard settings.isConfigured else { return false }
        do {
            return try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                stateRoot: stateRoot,
                fileManager: fileManager)
            {
                let wasDisconnected = operations.isDisconnected()
                let storedSettings = operations.loadStored()
                guard let artifactDisposition = self.artifactDisposition(
                    settings,
                    isDisconnected: wasDisconnected,
                    storedSettings: storedSettings)
                else { return false }
                guard let generationUpdate = CostUsageCacheLocations
                    .prepareCLIProxyAPIConfigurationGenerationUpdate(
                        stateRoot: stateRoot,
                        fileManager: fileManager)
                else { return false }
                defer {
                    CostUsageCacheLocations.discardCLIProxyAPIConfigurationGenerationUpdate(
                        generationUpdate,
                        fileManager: fileManager)
                }
                let artifactsUpdate: CostUsageCacheLocations.CLIProxyAPIArtifactsUpdate?
                switch artifactDisposition {
                case .preserve:
                    artifactsUpdate = nil
                case .purge:
                    guard let update = CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
                        in: artifactDirectories,
                        stateRoot: stateRoot,
                        expectedGeneration: generationUpdate.generation,
                        fileManager: fileManager,
                        disconnectedStateAfterCommit: false,
                        disconnectedStateAfterRollback: wasDisconnected,
                        prepareState: { operations.setDisconnectedState(true) })
                    else {
                        _ = operations.setDisconnectedState(wasDisconnected)
                        return false
                    }
                    artifactsUpdate = update
                }

                func rollback() {
                    if let artifactsUpdate {
                        guard CostUsageCacheLocations.markCLIProxyAPIArtifactsUpdateForRollback(
                            artifactsUpdate,
                            fileManager: fileManager)
                        else { return }
                    }
                    guard operations.restore(storedSettings) else { return }
                    if let artifactsUpdate {
                        guard CostUsageCacheLocations.markCLIProxyAPIArtifactsRollbackCredentialsRestored(
                            artifactsUpdate,
                            fileManager: fileManager)
                        else { return }
                    }
                    guard operations.setDisconnectedState(wasDisconnected) else { return }
                    if let artifactsUpdate {
                        _ = CostUsageCacheLocations.restoreCLIProxyAPIArtifactsUpdate(
                            artifactsUpdate,
                            fileManager: fileManager)
                    }
                }

                guard CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
                    generationUpdate,
                    fileManager: fileManager)
                else {
                    rollback()
                    return false
                }
                // Publish the telemetry invalidation before replacing credentials. If the process exits
                // during the Keychain write, recovery will discard the staged artifacts instead of exposing
                // telemetry collected under the previous credentials with the replacement configuration.
                guard operations.store(settings) else {
                    rollback()
                    return false
                }
                guard operations.setDisconnectedState(false) else {
                    rollback()
                    return false
                }
                if let artifactsUpdate {
                    CostUsageCacheLocations.discardCLIProxyAPIArtifactsUpdate(
                        artifactsUpdate,
                        fileManager: fileManager)
                }
                return true
            }
        } catch {
            return false
        }
    }

    @discardableResult
    public static func clear() -> Bool {
        do {
            return try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: nil) {
                self.clearUnserialized()
            }
        } catch {
            return false
        }
    }

    public static func removeAndPurgeTelemetry() -> CLIProxyAPIConfigurationRemovalResult {
        let fileManager = FileManager.default
        let directories = CostUsageCacheLocations.directories(fileManager: fileManager)
        return self.removeAndPurgeTelemetry(
            in: directories,
            stateRoot: directories[1].deletingLastPathComponent(),
            fileManager: fileManager,
            operations: SerializedRemovalOperations(
                isDisconnected: { CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected() },
                loadStored: {
                    self.storedSettingsSnapshot(from: KeychainCacheStore.load(
                        key: self.key,
                        as: CLIProxyAPIConnectionSettings.self))
                },
                clearConfiguration: { self.clearUnserialized() },
                setDisconnectedState: { CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected($0) },
                restore: { storedSettings in
                    self.restoreStoredSettings(
                        storedSettings,
                        store: { KeychainCacheStore.storeResult(key: self.key, entry: $0) },
                        clear: { KeychainCacheStore.clearResult(key: self.key) })
                }))
    }

    static func removeAndPurgeTelemetry(
        in directories: [URL],
        stateRoot: URL?,
        fileManager: FileManager,
        operations: SerializedRemovalOperations) -> CLIProxyAPIConfigurationRemovalResult
    {
        do {
            return try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                stateRoot: stateRoot,
                fileManager: fileManager)
            {
                let wasDisconnected = operations.isDisconnected()
                let storedSettings = operations.loadStored()
                if case .unavailable = storedSettings { return .configurationRemovalFailed }
                return self.removeAndPurgeTelemetryUnserialized(
                    in: directories,
                    stateRoot: stateRoot,
                    fileManager: fileManager,
                    snapshot: .init(
                        wasDisconnected: wasDisconnected,
                        storedSettings: storedSettings),
                    operations: operations)
            }
        } catch {
            return .configurationRemovalFailed
        }
    }

    private static func removeAndPurgeTelemetryUnserialized(
        in directories: [URL],
        stateRoot: URL?,
        fileManager: FileManager,
        snapshot: SerializedRemovalSnapshot,
        operations: SerializedRemovalOperations) -> CLIProxyAPIConfigurationRemovalResult
    {
        guard let generationUpdate = CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(
                stateRoot: stateRoot,
                fileManager: fileManager)
        else { return .configurationRemovalFailed }
        defer {
            CostUsageCacheLocations.discardCLIProxyAPIConfigurationGenerationUpdate(
                generationUpdate,
                fileManager: fileManager)
        }
        guard let artifactsUpdate = CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: directories,
            stateRoot: stateRoot,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager,
            disconnectedStateAfterRollback: snapshot.wasDisconnected,
            removalIsolationPublished: false,
            removalCredentialsCleared: false)
        else { return .configurationRemovalFailed }

        func rollback() {
            guard CostUsageCacheLocations.markCLIProxyAPIArtifactsUpdateForRollback(
                artifactsUpdate,
                fileManager: fileManager),
                operations.restore(snapshot.storedSettings),
                CostUsageCacheLocations.markCLIProxyAPIArtifactsRollbackCredentialsRestored(
                    artifactsUpdate,
                    fileManager: fileManager),
                operations.setDisconnectedState(snapshot.wasDisconnected)
            else { return }
            _ = CostUsageCacheLocations.restoreCLIProxyAPIArtifactsUpdate(
                artifactsUpdate,
                fileManager: fileManager)
        }

        guard CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager)
        else {
            rollback()
            return .configurationRemovalFailed
        }
        guard operations.setDisconnectedState(true),
              CostUsageCacheLocations.markCLIProxyAPIArtifactsRemovalIsolationPublished(
                  artifactsUpdate,
                  fileManager: fileManager)
        else {
            rollback()
            return .configurationRemovalFailed
        }
        // Isolation is transaction-owned and durable before Keychain deletion. Recovery can now finish
        // deletion without confusing a disconnect marker that predated this removal.
        guard operations.clearConfiguration() else {
            rollback()
            return .configurationRemovalFailed
        }
        guard CostUsageCacheLocations.markCLIProxyAPIArtifactsRemovalCredentialsCleared(
            artifactsUpdate,
            fileManager: fileManager)
        else {
            rollback()
            return .configurationRemovalFailed
        }
        return CostUsageCacheLocations.discardCLIProxyAPIArtifactsUpdate(
            artifactsUpdate,
            fileManager: fileManager) ? .removed : .telemetryCleanupFailed
    }

    static func recoverInterruptedRemovalUnserialized(
        stateRoot: URL?,
        fileManager: FileManager) -> Bool
    {
        self.clearUnserialized(
            isDisconnected: {
                CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
                    stateRoot: stateRoot,
                    fileManager: fileManager)
            },
            setDisconnectedState: {
                CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
                    $0,
                    stateRoot: stateRoot,
                    fileManager: fileManager)
            },
            clearConfiguration: { KeychainCacheStore.clearResult(key: self.key) })
    }

    private static func clearUnserialized() -> Bool {
        self.clearUnserialized(
            isDisconnected: { CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected() },
            setDisconnectedState: { CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected($0) },
            clearConfiguration: { KeychainCacheStore.clearResult(key: self.key) })
    }

    static func clearUnserialized(
        isDisconnected: () -> Bool,
        setDisconnectedState: (Bool) -> Bool,
        clearConfiguration: () -> KeychainCacheStore.ClearResult) -> Bool
    {
        let wasDisconnected = isDisconnected()
        guard wasDisconnected || setDisconnectedState(true) else {
            return false
        }

        switch clearConfiguration() {
        case .removed, .missing:
            return true
        case .failed:
            if !wasDisconnected {
                _ = setDisconnectedState(false)
            }
            return false
        }
    }
}

public enum CLIProxyAPIConfigurationRemovalResult: Equatable, Sendable {
    case removed
    case configurationRemovalFailed
    case telemetryCleanupFailed
}

public enum CLIProxyAPIUsageCollectionResult: Equatable, Sendable {
    case disabled
    case notConfigured
    case collected(Int)
    case failed(String)
}

private actor CLIProxyAPIUsageCollectionGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        await self.acquire()
        let result = await operation()
        self.release()
        return result
    }

    private func acquire() async {
        if !self.isLocked {
            self.isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    private func release() {
        guard !self.waiters.isEmpty else {
            self.isLocked = false
            return
        }
        self.waiters.removeFirst().resume()
    }
}

public enum CLIProxyAPIUsageCollector {
    private static let maximumBatches = 10
    private static let batchSize = 100
    private static let collectionGate = CLIProxyAPIUsageCollectionGate()

    @discardableResult
    public static func pruneExpiredUsage(now: Date = Date()) -> Bool {
        self.pruneExpiredUsage(
            cacheRoot: nil,
            pendingRoot: nil,
            stateRoot: nil,
            now: now)
    }

    @discardableResult
    static func pruneExpiredUsage(
        cacheRoot: URL?,
        pendingRoot: URL?,
        stateRoot: URL?,
        now: Date,
        fileManager: FileManager = .default) -> Bool
    {
        do {
            return try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                stateRoot: stateRoot,
                fileManager: fileManager)
            {
                let pendingPruned = CLIProxyAPIUsagePendingIO.load(pendingRoot: pendingRoot, now: now) != nil
                let durablePruned = CLIProxyAPIUsageCacheIO.pruneUnserialized(cacheRoot: cacheRoot, now: now)
                return pendingPruned && durablePruned
            }
        } catch {
            return false
        }
    }

    public static func collect(
        cacheRoot: URL? = nil,
        shouldContinue: @escaping @Sendable () async -> Bool = { true }) async
        -> CLIProxyAPIUsageCollectionResult
    {
        await self.collect(
            cacheRoot: cacheRoot,
            settingsResult: CLIProxyAPIConnectionSettingsStore.loadResult(),
            shouldContinue: shouldContinue)
    }

    static func collect(
        cacheRoot: URL? = nil,
        settingsResult: KeychainCacheStore.LoadResult<CLIProxyAPIConnectionSettings>,
        shouldContinue: @escaping @Sendable () async -> Bool = { true }) async
        -> CLIProxyAPIUsageCollectionResult
    {
        switch settingsResult {
        case let .found(settings):
            await self.collect(
                cacheRoot: cacheRoot,
                settings: settings,
                shouldContinue: shouldContinue)
        case .temporarilyUnavailable:
            .failed("CLIProxyAPI configuration is temporarily unavailable.")
        case .missing, .invalid:
            .notConfigured
        }
    }

    public static func collect(
        cacheRoot: URL? = nil,
        settings: CLIProxyAPIConnectionSettings?,
        shouldContinue: @escaping @Sendable () async -> Bool = { true }) async
        -> CLIProxyAPIUsageCollectionResult
    {
        await self.collect(
            cacheRoot: cacheRoot,
            settings: settings,
            currentSettingsResult: { CLIProxyAPIConnectionSettingsStore.loadResult() },
            shouldContinue: shouldContinue)
    }

    static func collect(
        cacheRoot: URL? = nil,
        settings: CLIProxyAPIConnectionSettings?,
        currentSettingsResult: @escaping @Sendable ()
            -> KeychainCacheStore.LoadResult<CLIProxyAPIConnectionSettings>,
        shouldContinue: @escaping @Sendable () async -> Bool = { true },
        client: CLIProxyAPIUsageQueueClient? = nil) async
        -> CLIProxyAPIUsageCollectionResult
    {
        guard let settings, settings.isConfigured else { return .notConfigured }
        let stateRoot = cacheRoot?.deletingLastPathComponent()
        let configurationGeneration = CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(stateRoot: stateRoot)
        return await self.collect(
            cacheRoot: cacheRoot,
            configurationIsCurrent: {
                guard !CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(stateRoot: stateRoot)
                else { return false }
                return switch currentSettingsResult() {
                case let .found(currentSettings): currentSettings == settings
                case .temporarilyUnavailable:
                    CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(stateRoot: stateRoot) ==
                        configurationGeneration
                case .missing, .invalid: false
                }
            },
            shouldContinue: shouldContinue,
            client: client ?? CLIProxyAPIUsageQueueClient(settings: settings))
    }

    static func collect(
        cacheRoot: URL? = nil,
        pendingRoot: URL? = nil,
        configurationIsCurrent: @escaping @Sendable () -> Bool = { true },
        shouldContinue: @escaping @Sendable () async -> Bool = { true },
        client: CLIProxyAPIUsageQueueClient) async -> CLIProxyAPIUsageCollectionResult
    {
        guard configurationIsCurrent() else { return .notConfigured }
        return await self.collectionGate.perform {
            do {
                return try await CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                    stateRoot: cacheRoot?.deletingLastPathComponent())
                {
                    guard configurationIsCurrent() else { return .notConfigured }
                    return await self.collectUnserialized(
                        cacheRoot: cacheRoot,
                        pendingRoot: pendingRoot,
                        configurationIsCurrent: configurationIsCurrent,
                        shouldContinue: shouldContinue,
                        client: client)
                }
            } catch {
                return .failed("Could not lock CLIProxyAPI usage telemetry: \(error.localizedDescription)")
            }
        }
    }

    private static func collectUnserialized(
        cacheRoot: URL?,
        pendingRoot: URL?,
        configurationIsCurrent: @escaping @Sendable () -> Bool,
        shouldContinue: @escaping @Sendable () async -> Bool,
        client: CLIProxyAPIUsageQueueClient) async -> CLIProxyAPIUsageCollectionResult
    {
        do {
            var added = 0
            let effectivePendingRoot = pendingRoot ?? cacheRoot
            guard let pendingRecords = CLIProxyAPIUsagePendingIO.load(pendingRoot: effectivePendingRoot) else {
                return .failed("Could not load pending CLIProxyAPI usage telemetry.")
            }
            if !pendingRecords.isEmpty {
                guard let pendingAdded = CLIProxyAPIUsageCacheIO.merge(
                    pendingRecords,
                    cacheRoot: cacheRoot)
                else {
                    return .failed("Could not save CLIProxyAPI usage telemetry.")
                }
                added += pendingAdded
                guard CLIProxyAPIUsagePendingIO.clear(pendingRoot: effectivePendingRoot) else {
                    return .failed("Could not clear pending CLIProxyAPI usage telemetry.")
                }
            }

            for _ in 0..<self.maximumBatches {
                guard configurationIsCurrent() else { return .notConfigured }
                guard !Task.isCancelled, await shouldContinue() else { return .disabled }
                let poppedBatch = try await Task.detached(priority: .utility) {
                    try await client.pop(count: self.batchSize)
                }.value
                let stagedRecords = poppedBatch.records.map { $0.assigningNewLocalOccurrenceID() }
                if !poppedBatch.records.isEmpty {
                    guard CLIProxyAPIUsagePendingIO.save(
                        stagedRecords,
                        pendingRoot: effectivePendingRoot)
                    else {
                        return .failed("Could not stage CLIProxyAPI usage telemetry.")
                    }
                }
                guard let batchAdded = CLIProxyAPIUsageCacheIO.merge(
                    stagedRecords,
                    cacheRoot: cacheRoot)
                else {
                    return .failed("Could not save CLIProxyAPI usage telemetry.")
                }
                added += batchAdded
                if !poppedBatch.records.isEmpty,
                   !CLIProxyAPIUsagePendingIO.clear(pendingRoot: effectivePendingRoot)
                {
                    return .failed("Could not clear pending CLIProxyAPI usage telemetry.")
                }
                if poppedBatch.receivedCount < self.batchSize {
                    break
                }
            }
            return .collected(added)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct CLIProxyAPIUsageQueueClient: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct PoppedBatch: Sendable {
        let records: [CLIProxyAPIUsageRecord]
        let receivedCount: Int
    }

    private struct LossyRecord: Decodable {
        let value: CLIProxyAPIUsageRecord?

        init(from decoder: Decoder) {
            self.value = try? CLIProxyAPIUsageRecord(from: decoder)
        }
    }

    private static let log = CodexBarLog.logger(LogCategories.tokenCost)

    enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL: "Invalid CLIProxyAPI URL."
            case .invalidResponse: "CLIProxyAPI returned an invalid response."
            case let .httpError(status): "CLIProxyAPI returned HTTP \(status)."
            }
        }
    }

    let settings: CLIProxyAPIConnectionSettings
    let dataLoader: DataLoader

    init(
        settings: CLIProxyAPIConnectionSettings,
        dataLoader: @escaping DataLoader = Self.liveDataLoader)
    {
        self.settings = settings
        self.dataLoader = dataLoader
    }

    func pop(count: Int) async throws -> PoppedBatch {
        guard let baseURL = self.settings.resolvedBaseURL,
              var components = URLComponents(
                  url: baseURL.appendingPathComponent("v0/management/usage-queue"),
                  resolvingAgainstBaseURL: false)
        else { throw ClientError.invalidBaseURL }
        components.queryItems = [URLQueryItem(name: "count", value: String(max(1, count)))]
        guard let url = components.url else { throw ClientError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(self.settings.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.httpError(httpResponse.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = CostUsageDateParser.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid CLIProxyAPI usage timestamp.")
            }
            return date
        }
        let decoded = try decoder.decode([LossyRecord].self, from: data)
        let records = decoded.compactMap(\.value)
        let malformedCount = decoded.count - records.count
        if malformedCount > 0 {
            Self.log.warning(
                "Ignored malformed CLIProxyAPI usage records",
                metadata: ["count": String(malformedCount)])
        }
        return PoppedBatch(records: records, receivedCount: decoded.count)
    }

    private static func liveDataLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return try await URLSession(configuration: configuration).data(for: request)
    }
}
