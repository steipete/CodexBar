import Foundation

/// Disk cache for per-file Grok `updates.jsonl` parse results so budget-deferred archives
/// catch up across refreshes without re-reading unchanged newest sessions every time.
///
/// Retention contract (privacy):
/// - Local-only under the user Caches directory; never uploaded.
/// - Entries older than ``maxEntryAge`` (by session-file mtime) are dropped on load/save.
/// - The whole artifact is deleted when Cost tracking is disabled (see Settings) or via
///   `codexbar cache clear --cost` / Debug clear.
public enum GrokTurnUsageCacheIO {
    private static let artifactVersion = 2

    /// Match shared cost-cache safety budgets: decode/encode is whole-document JSON, so an
    /// unbounded local history can otherwise grow the artifact without limit and spike memory.
    public static let maxCacheFileBytes: Int = 256 * 1024 * 1024
    public static let maxCacheLoadBytes: Int = 320 * 1024 * 1024
    /// Soft cap on cached session files; oldest (by mtime) are dropped first when over budget.
    public static let maxCacheFileEntries: Int = 10000
    /// Drop session-file entries whose mtime is older than this age (privacy expiry).
    public static let maxEntryAgeDays: Int = 90
    public static var maxEntryAge: TimeInterval {
        TimeInterval(maxEntryAgeDays) * 24 * 60 * 60
    }

    /// Test-only override for the default cache root so Settings disable/delete paths
    /// do not touch the real user Caches directory.
    nonisolated(unsafe) static var testDefaultCacheRoot: URL?

    private static func defaultCacheRoot() -> URL {
        if let override = testDefaultCacheRoot {
            return override
        }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    public static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("grok-turns-v\(Self.artifactVersion).json", isDirectory: false)
    }

    /// Remove the on-disk Grok parse cache (best-effort). Safe when the file is already gone.
    @discardableResult
    public static func deleteCache(cacheRoot: URL? = nil) -> Bool {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    static func load(
        cacheRoot: URL? = nil,
        maxLoadBytes: Int = GrokTurnUsageCacheIO.maxCacheLoadBytes,
        now: Date = Date(),
        maxEntryAge: TimeInterval = GrokTurnUsageCacheIO.maxEntryAge) -> GrokTurnUsageCache
    {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        // Refuse oversized artifacts before materializing them (same pattern as CostUsageCacheIO).
        guard fileSize > 0, fileSize <= Int64(max(0, maxLoadBytes)) else {
            return GrokTurnUsageCache(version: Self.artifactVersion)
        }
        guard let data = try? Data(contentsOf: url),
              data.count <= maxLoadBytes,
              var decoded = try? JSONDecoder().decode(GrokTurnUsageCache.self, from: data),
              decoded.version == Self.artifactVersion
        else {
            return GrokTurnUsageCache(version: Self.artifactVersion)
        }
        let beforeCount = decoded.files.count
        Self.pruneExpired(&decoded, now: now, maxAge: maxEntryAge)
        // Drop empty/fully-expired artifacts so path keys are not retained on disk.
        if decoded.files.isEmpty {
            if beforeCount > 0 || fileSize > 0 {
                _ = Self.deleteCache(cacheRoot: cacheRoot)
            }
            return GrokTurnUsageCache(version: Self.artifactVersion)
        }
        return decoded
    }

    static func save(
        cache: GrokTurnUsageCache,
        cacheRoot: URL? = nil,
        maxFileBytes: Int = GrokTurnUsageCacheIO.maxCacheFileBytes,
        maxFileEntries: Int = GrokTurnUsageCacheIO.maxCacheFileEntries,
        now: Date = Date(),
        maxEntryAge: TimeInterval = GrokTurnUsageCacheIO.maxEntryAge)
    {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.version = Self.artifactVersion
        Self.pruneExpired(&cache, now: now, maxAge: maxEntryAge)
        if cache.files.isEmpty {
            _ = Self.deleteCache(cacheRoot: cacheRoot)
            return
        }
        Self.pruneForBudget(
            &cache,
            maxFileBytes: maxFileBytes,
            maxFileEntries: maxFileEntries)
        if cache.files.isEmpty {
            _ = Self.deleteCache(cacheRoot: cacheRoot)
            return
        }

        let tmp = dir.appendingPathComponent(".tmp-grok-\(UUID().uuidString).json", isDirectory: false)
        guard let data = try? JSONEncoder().encode(cache), !data.isEmpty else { return }
        // Last-resort: if still over budget after entry pruning, do not persist an oversized artifact.
        guard data.count <= max(0, maxFileBytes) else {
            // Drop half the oldest files and try once more; give up rather than write unbounded.
            Self.dropOldestFiles(&cache, keepCount: max(1, cache.files.count / 2))
            guard let retry = try? JSONEncoder().encode(cache),
                  retry.count <= max(0, maxFileBytes)
            else { return }
            self.writeAtomically(retry, to: url, temporary: tmp)
            return
        }
        self.writeAtomically(data, to: url, temporary: tmp)
    }

    /// Drop session-file entries whose mtime is older than `maxAge`.
    static func pruneExpired(
        _ cache: inout GrokTurnUsageCache,
        now: Date = Date(),
        maxAge: TimeInterval = GrokTurnUsageCacheIO.maxEntryAge)
    {
        guard maxAge > 0, !cache.files.isEmpty else { return }
        let cutoffMs = Int64(((now.timeIntervalSince1970 - maxAge) * 1000).rounded())
        cache.files = cache.files.filter { _, file in
            file.mtimeUnixMs >= cutoffMs
        }
    }

    /// Prefer newest session files; drop oldest when over entry or encoded-size budget.
    static func pruneForBudget(
        _ cache: inout GrokTurnUsageCache,
        maxFileBytes: Int,
        maxFileEntries: Int)
    {
        if maxFileEntries > 0, cache.files.count > maxFileEntries {
            self.dropOldestFiles(&cache, keepCount: maxFileEntries)
        }
        // Estimate before encoding when possible; encode only if still large after entry trim.
        guard maxFileBytes > 0 else { return }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        guard data.count > maxFileBytes else { return }

        // Binary-search-ish: drop oldest files until under budget or nearly empty.
        var keep = max(1, cache.files.count / 2)
        while cache.files.count > 1 {
            Self.dropOldestFiles(&cache, keepCount: keep)
            guard let trimmed = try? JSONEncoder().encode(cache) else { return }
            if trimmed.count <= maxFileBytes { return }
            keep = max(1, cache.files.count / 2)
            if keep >= cache.files.count { break }
        }
    }

    static func dropOldestFiles(_ cache: inout GrokTurnUsageCache, keepCount: Int) {
        guard keepCount >= 0, cache.files.count > keepCount else { return }
        let ordered = cache.files.sorted { lhs, rhs in
            if lhs.value.mtimeUnixMs != rhs.value.mtimeUnixMs {
                return lhs.value.mtimeUnixMs > rhs.value.mtimeUnixMs // newest first
            }
            return lhs.key < rhs.key
        }
        let kept = ordered.prefix(keepCount)
        cache.files = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private static func writeAtomically(_ data: Data, to url: URL, temporary tmp: URL) {
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

struct GrokTurnUsageCache: Codable, Equatable {
    var version: Int
    /// Path → last successful full-file parse.
    var files: [String: GrokTurnUsageCachedFile] = [:]

    init(version: Int = 2) {
        self.version = version
    }
}

struct GrokTurnUsageCachedFile: Codable, Equatable {
    var mtimeUnixMs: Int64
    var size: Int64
    var sessionID: String
    var cwd: String?
    /// True when only a bounded slice of the file was parsed (oversized archive).
    var isPartial: Bool
    var turns: [GrokTurnUsageCachedTurn]

    init(
        mtimeUnixMs: Int64,
        size: Int64,
        sessionID: String,
        cwd: String?,
        isPartial: Bool = false,
        turns: [GrokTurnUsageCachedTurn])
    {
        self.mtimeUnixMs = mtimeUnixMs
        self.size = size
        self.sessionID = sessionID
        self.cwd = cwd
        self.isPartial = isPartial
        self.turns = turns
    }
}

struct GrokTurnUsageCachedTurn: Codable, Equatable {
    var eventID: String
    var sessionID: String
    var dayKey: String
    var timestampUnixMs: Int64
    var cwd: String?
    var inputTokens: Int
    var cacheReadTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var modelCalls: Int
    var costUSD: Double?
    var modelUsages: [GrokTurnUsageCachedModel]

    init(from record: GrokTurnUsageScanner.TurnRecord) {
        self.eventID = record.eventID
        self.sessionID = record.sessionID
        self.dayKey = record.dayKey
        self.timestampUnixMs = Int64((record.timestamp.timeIntervalSince1970 * 1000).rounded())
        self.cwd = record.cwd
        self.inputTokens = record.inputTokens
        self.cacheReadTokens = record.cacheReadTokens
        self.outputTokens = record.outputTokens
        self.reasoningTokens = record.reasoningTokens
        self.totalTokens = record.totalTokens
        self.modelCalls = record.modelCalls
        self.costUSD = record.costUSD
        self.modelUsages = record.modelUsages.map(GrokTurnUsageCachedModel.init(from:))
    }

    func asTurnRecord() -> GrokTurnUsageScanner.TurnRecord {
        GrokTurnUsageScanner.TurnRecord(
            eventID: self.eventID,
            sessionID: self.sessionID,
            dayKey: self.dayKey,
            timestamp: Date(timeIntervalSince1970: TimeInterval(self.timestampUnixMs) / 1000),
            cwd: self.cwd,
            inputTokens: self.inputTokens,
            cacheReadTokens: self.cacheReadTokens,
            outputTokens: self.outputTokens,
            reasoningTokens: self.reasoningTokens,
            totalTokens: self.totalTokens,
            modelCalls: self.modelCalls,
            costUSD: self.costUSD,
            modelUsages: self.modelUsages.map { $0.asModelUsage() })
    }
}

struct GrokTurnUsageCachedModel: Codable, Equatable {
    var modelName: String
    var inputTokens: Int
    var cacheReadTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var modelCalls: Int
    var costUSD: Double?

    init(from usage: GrokTurnUsageScanner.ModelUsage) {
        self.modelName = usage.modelName
        self.inputTokens = usage.inputTokens
        self.cacheReadTokens = usage.cacheReadTokens
        self.outputTokens = usage.outputTokens
        self.reasoningTokens = usage.reasoningTokens
        self.totalTokens = usage.totalTokens
        self.modelCalls = usage.modelCalls
        self.costUSD = usage.costUSD
    }

    func asModelUsage() -> GrokTurnUsageScanner.ModelUsage {
        GrokTurnUsageScanner.ModelUsage(
            modelName: self.modelName,
            inputTokens: self.inputTokens,
            cacheReadTokens: self.cacheReadTokens,
            outputTokens: self.outputTokens,
            reasoningTokens: self.reasoningTokens,
            totalTokens: self.totalTokens,
            modelCalls: self.modelCalls,
            costUSD: self.costUSD)
    }
}
