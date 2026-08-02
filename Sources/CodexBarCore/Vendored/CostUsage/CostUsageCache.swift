import Foundation

enum CostUsageCacheIO {
    /// Producer keys from older parser hashes whose caches are still valid under the current
    /// delta semantics. Cleared for #2037: interleave containment changed how cumulative
    /// totals are counted, so every earlier cache must be rebuilt.
    private static let compatibleCodexProducerKeys: Set<String> = []

    /// Parsing and attribution changes rotate the Codex parser producer key.
    /// Increment this artifact version only when the stored schema or cache layout becomes incompatible.
    private static func artifactVersion(for provider: UsageProvider) -> Int {
        switch provider {
        case .codex:
            11
        case .claude, .vertexai:
            6
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
        producerKey: String? = nil,
        calendar: Calendar? = nil) -> CostUsageCache
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: provider)
        let compatibleProducerKeys = producerKey == nil && provider == .codex
            ? self.compatibleCodexProducerKeys
            : []
        if let decoded = self.loadCache(
            at: url,
            expectedProducerKey: expectedProducerKey,
            compatibleProducerKeys: compatibleProducerKeys)
        {
            if let calendar, decoded.timeZoneIdentifier != calendar.timeZone.identifier {
                return CostUsageCache()
            }
            return decoded
        }
        return CostUsageCache()
    }

    private static func loadCache(
        at url: URL,
        expectedProducerKey: String?,
        compatibleProducerKeys: Set<String>) -> CostUsageCache?
    {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data)
        else { return nil }
        guard decoded.version == 1 else { return nil }
        if let expectedProducerKey {
            guard decoded.producerKey == expectedProducerKey
                || decoded.producerKey.map(compatibleProducerKeys.contains) == true
            else { return nil }
        }
        return decoded
    }

    static func save(
        provider: UsageProvider,
        cache: CostUsageCache,
        cacheRoot: URL? = nil,
        producerKey: String? = nil,
        calendar: Calendar = .current)
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.producerKey = producerKey ?? self.currentProducerKey(provider: provider)
        cache.timeZoneIdentifier = calendar.timeZone.identifier

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
        parserHash: String = CodexParserHash.value) -> String?
    {
        guard provider == .codex else { return nil }
        return "\(provider.rawValue):cu:p\(parserHash)"
    }
}

struct CostUsageCache: Codable {
    var version: Int = 1
    var producerKey: String?
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var codexPricingKey: String?
    var codexPriorityMetadataKey: String?
    var codexProjectMetadataVersion: Int?
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
    var lastRawTotalsWatermark: CostUsageCodexTotals?
    var seenRawTotals: [CostUsageCodexTotals]?
    var hasDivergentTotals: Bool?
    var hasInterleavedTotals: Bool?
    var lastCodexTurnID: String?
    var sessionId: String?
    var forkedFromId: String?
    var forkBaselineDependencyKey: String?
    var projectPath: String?
    var canonicalProjectPath: String?
    var codexCostCacheComplete: Bool?
    var codexSession: CostUsageCodexSessionMetadata?
    var codexCostNanos: [String: [String: Int64]]?
    var codexPrioritySurchargeNanos: [String: [String: Int64]]?
    var codexStandardCostNanos: [String: [String: Int64]]?
    var codexPriorityCostNanos: [String: [String: Int64]]?
    var codexStandardTokens: [String: [String: Int]]?
    var codexPriorityTokens: [String: [String: Int]]?
    var codexTurnIDs: [String]?
    /// Refreshed by Codex normalization paths, never by sidecar cache validation.
    var codexWorkspaceContentFingerprint: String?
    var codexRows: [CostUsageScanner.CodexUsageRow]?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
    /// Identity and target size for an in-progress bounded Codex parse.
    var codexScanFileId: String?
    var codexScanTargetSize: Int64?
    var codexScanComplete: Bool?
    var codexJSONLResumeState: CostUsageJsonl.ResumeState?
    /// Compact relevant events retained while a subagent rollout awaits full-shape classification.
    var codexBufferedSubagentLines: [CostUsageScanner.CodexBufferedFastLine]?
}

struct CostUsageCodexSessionMetadata: Codable, Equatable {
    var sessionId: String?
    var forkedFromId: String?
    var cwd: String?
    var title: String?
    var startedAtUnixMs: Int64?
    var latestActivityUnixMs: Int64?

    var isEmpty: Bool {
        self.sessionId == nil
            && self.forkedFromId == nil
            && self.cwd == nil
            && self.title == nil
            && self.startedAtUnixMs == nil
            && self.latestActivityUnixMs == nil
    }

    func merging(_ newer: CostUsageCodexSessionMetadata) -> CostUsageCodexSessionMetadata {
        CostUsageCodexSessionMetadata(
            sessionId: newer.sessionId ?? self.sessionId,
            forkedFromId: newer.forkedFromId ?? self.forkedFromId,
            cwd: newer.cwd ?? self.cwd,
            title: newer.title ?? self.title,
            startedAtUnixMs: Self.earlier(self.startedAtUnixMs, newer.startedAtUnixMs),
            latestActivityUnixMs: Self.later(self.latestActivityUnixMs, newer.latestActivityUnixMs))
    }

    private static func earlier(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func later(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}

struct CostUsageCodexTotals: Codable, Equatable {
    var input: Int
    var cached: Int
    var output: Int
    var reasoning: Int?

    init(input: Int, cached: Int, output: Int, reasoning: Int? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
    }
}
