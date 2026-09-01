import Foundation

/// Per-file scan cache for Muse session logs.
///
/// Session logs are append-only and dominated by telemetry the reader discards, so re-reading an
/// unchanged file on every refresh is pure waste. Each entry stores the file's size and modification
/// time alongside the per-day totals it contributed; a file whose size and mtime both match is reused
/// without opening it, turning a full rescan into a stat of each path.
struct MuseLocalUsageCache: Codable {
    struct DayTotals: Codable, Equatable {
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var reasoningTokens: Int
        var totalTokens: Int
        var requestCount: Int
        var models: [String: Int]

        init(
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cacheReadTokens: Int = 0,
            cacheWriteTokens: Int = 0,
            reasoningTokens: Int = 0,
            totalTokens: Int = 0,
            requestCount: Int = 0,
            models: [String: Int] = [:])
        {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.requestCount = requestCount
            self.models = models
        }
    }

    struct FileEntry: Codable {
        var size: Int
        var modifiedAtMs: Int64
        /// Event ids this file contributed, so a turn copied into a second log is still counted once.
        var eventIDs: [String]
        var days: [String: DayTotals]
        var isComplete: Bool
    }

    var version: Int
    var timeZoneIdentifier: String?
    var files: [String: FileEntry] = [:]
}

enum MuseLocalUsageCacheIO {
    /// Artifact schema version; bump when the parser or the stored shape changes.
    private static let artifactVersion = 1

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("muse-sessions-v\(Self.artifactVersion).json", isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil, calendar: Calendar = .current) -> MuseLocalUsageCache {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MuseLocalUsageCache.self, from: data),
              decoded.version == Self.artifactVersion,
              // Day keys are timezone-dependent, so a moved machine must rebucket from scratch.
              decoded.timeZoneIdentifier == calendar.timeZone.identifier
        else {
            return MuseLocalUsageCache(version: Self.artifactVersion)
        }
        return decoded
    }

    static func save(cache: MuseLocalUsageCache, cacheRoot: URL? = nil, calendar: Calendar = .current) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        guard let data = try? JSONEncoder().encode(cache) else { return }
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
