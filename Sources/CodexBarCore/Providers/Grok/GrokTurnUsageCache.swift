import Foundation

/// Disk cache for per-file Grok `updates.jsonl` parse results so budget-deferred archives
/// catch up across refreshes without re-reading unchanged newest sessions every time.
enum GrokTurnUsageCacheIO {
    private static let artifactVersion = 2

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("grok-turns-v\(Self.artifactVersion).json", isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil) -> GrokTurnUsageCache {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GrokTurnUsageCache.self, from: data),
              decoded.version == Self.artifactVersion
        else {
            return GrokTurnUsageCache(version: Self.artifactVersion)
        }
        return decoded
    }

    static func save(cache: GrokTurnUsageCache, cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".tmp-grok-\(UUID().uuidString).json", isDirectory: false)
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
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
