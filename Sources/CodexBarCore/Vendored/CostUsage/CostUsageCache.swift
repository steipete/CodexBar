import Foundation

enum CostUsageCacheIO {
    private static func artifactVersion(for provider: UsageProvider) -> Int {
        switch provider {
        case .codex:
            8
        case .claude, .vertexai:
            2
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
        let artifactVersion = self.artifactVersion(for: provider)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-v\(artifactVersion).json", isDirectory: false)
    }

    static func load(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        producerKey: String? = nil) -> CostUsageCache
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: provider)
        if let decoded = self.loadCache(at: url, expectedProducerKey: expectedProducerKey) { return decoded }
        return CostUsageCache()
    }

    private static func loadCache(at url: URL, expectedProducerKey: String?) -> CostUsageCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data)
        else { return nil }
        guard decoded.version == 1 else { return nil }
        if let expectedProducerKey {
            guard decoded.producerKey == expectedProducerKey else { return nil }
        }
        return decoded
    }

    static func save(
        provider: UsageProvider,
        cache: CostUsageCache,
        cacheRoot: URL? = nil,
        producerKey: String? = nil)
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.producerKey = producerKey ?? self.currentProducerKey(provider: provider)

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
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

    static func currentProducerKey(
        provider: UsageProvider,
        bundle: Bundle = .main,
        executablePath: String? = CommandLine.arguments.first) -> String?
    {
        guard provider == .codex else { return nil }
        let version = self.currentCodexBarVersion(bundle: bundle, executablePath: executablePath)
        return "\(provider.rawValue):cost-usage:\(version)"
    }

    private static func currentCodexBarVersion(
        bundle: Bundle = .main,
        executablePath: String? = CommandLine.arguments.first) -> String
    {
        if let executablePath, !executablePath.isEmpty {
            let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            if let version = Self.adjacentVersionFileVersion(for: executableURL) {
                return version
            }
            if let version = Self.containingAppVersion(for: executableURL) {
                return version
            }
        }

        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        if let version = Self.normalizedVersionComponent(version) {
            return version
        }
        if let executablePath, !executablePath.isEmpty {
            let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            if let fingerprint = Self.executableFingerprint(for: executableURL) {
                return "development+\(fingerprint)"
            }
        }
        return "development"
    }

    private static func adjacentVersionFileVersion(for executableURL: URL) -> String? {
        let versionURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("VERSION")
        guard let raw = try? String(contentsOf: versionURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("v"), trimmed.dropFirst().first?.isNumber == true {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func containingAppVersion(for executableURL: URL) -> String? {
        var currentURL = executableURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        while currentURL.path != currentURL.deletingLastPathComponent().path {
            if currentURL.pathExtension == "app" {
                let infoURL = currentURL
                    .appendingPathComponent("Contents")
                    .appendingPathComponent("Info.plist")
                guard let data = fileManager.contents(atPath: infoURL.path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { return nil }
                return Self.normalizedVersionComponent(plist["CFBundleShortVersionString"] as? String)
            }
            currentURL.deleteLastPathComponent()
        }

        return nil
    }

    private static func normalizedVersionComponent(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "CodexBar"
        else { return nil }
        return trimmed
    }

    private static func executableFingerprint(for executableURL: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path) else {
            return nil
        }
        let size = attributes[.size] as? NSNumber
        let modifiedAt = attributes[.modificationDate] as? Date
        guard let size, let modifiedAt else { return nil }
        let modifiedMs = Int64(modifiedAt.timeIntervalSince1970 * 1000)
        return "\(size.int64Value)-\(modifiedMs)"
    }
}

struct CostUsageCache: Codable {
    var version: Int = 1
    var producerKey: String?
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var codexPricingKey: String?
    var codexPriorityMetadataKey: String?
    var codexPriorityTurnKeys: [String: String]?
    var codexPriorityTurnIDsByDay: [String: [String]]?

    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]

    /// dayKey -> model -> packed usage
    var days: [String: [String: [Int]]] = [:]

    /// rootPath -> mtime (for Claude roots)
    var roots: [String: Int64]?
}

struct CostUsageFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    var lastTotals: CostUsageCodexTotals?
    var lastCountedTotals: CostUsageCodexTotals?
    var lastRawTotalsBaseline: CostUsageCodexTotals?
    var hasDivergentTotals: Bool?
    var lastCodexTurnID: String?
    var sessionId: String?
    var forkedFromId: String?
    var codexCostNanos: [String: [String: Int64]]?
    var codexPrioritySurchargeNanos: [String: [String: Int64]]?
    var codexTurnIDs: [String]?
    var codexRows: [CostUsageScanner.CodexUsageRow]?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
}

struct CostUsageCodexTotals: Codable {
    var input: Int
    var cached: Int
    var output: Int
}
