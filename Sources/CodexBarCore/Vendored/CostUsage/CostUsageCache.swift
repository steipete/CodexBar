import Foundation

enum CostUsageCacheIO {
    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    /// Cache version - bump when pricing or calculation logic changes to invalidate old caches.
    private static let cacheVersion = 2

    static func cacheFileURL(provider: UsageProvider, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-v\(self.cacheVersion).json", isDirectory: false)
    }

    static func load(provider: UsageProvider, cacheRoot: URL? = nil) -> CostUsageCache {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        if let decoded = self.loadCache(at: url) { return decoded }
        return CostUsageCache()
    }

    private static func loadCache(at url: URL) -> CostUsageCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data)
        else { return nil }
        guard decoded.version == self.cacheVersion else { return nil }
        return decoded
    }

    static func save(provider: UsageProvider, cache: CostUsageCache, cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        do {
            try data.write(to: tmp, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

struct CostUsageCache: Codable, Sendable {
    var version: Int = 2
    var lastScanUnixMs: Int64 = 0

    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]

    /// dayKey -> model -> packed usage
    var days: [String: [String: [Int]]] = [:]

    /// rootPath -> mtime (for Claude roots)
    var roots: [String: Int64]?
}

struct CostUsageFileUsage: Codable, Sendable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    var lastTotals: CostUsageCodexTotals?
    var sessionId: String?
}

struct CostUsageCodexTotals: Codable, Sendable {
    var input: Int
    var cached: Int
    var output: Int
}
