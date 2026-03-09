import Foundation

enum CostUsageCacheIO {
    private static func cacheVersion(for provider: UsageProvider) -> Int {
        switch provider {
        case .codex:
            4
        default:
            1
        }
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(provider: UsageProvider, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        let version = self.cacheVersion(for: provider)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-v\(version).json", isDirectory: false)
    }

    static func load(provider: UsageProvider, cacheRoot: URL? = nil) -> CostUsageCache {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let version = self.cacheVersion(for: provider)
        if let decoded = self.loadCache(at: url, version: version) { return decoded }
        return CostUsageCache()
    }

    private static func loadCache(at url: URL, version: Int) -> CostUsageCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data)
        else { return nil }
        guard decoded.version == version else { return nil }
        return decoded
    }

    static func save(provider: UsageProvider, cache: CostUsageCache, cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        var cacheToSave = cache
        cacheToSave.version = self.cacheVersion(for: provider)
        let data = (try? JSONEncoder().encode(cacheToSave)) ?? Data()
        do {
            try data.write(to: tmp, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

struct CostUsageCache: Codable, Sendable {
    var version: Int = 1
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
