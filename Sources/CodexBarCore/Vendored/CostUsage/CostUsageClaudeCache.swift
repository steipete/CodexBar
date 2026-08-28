import Foundation

struct CostUsageClaudeFileStamp: Equatable, Sendable {
    let fileID: String
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    var mtimeUnixMs: Int64 {
        self.modifiedSeconds * 1000 + self.modifiedNanoseconds / 1_000_000
    }

    static func read(at url: URL) -> Self? {
        var info = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { return nil }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        #if os(Linux)
        let modifiedSeconds = Int64(info.st_mtim.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        #else
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #endif
        return Self(
            fileID: "\(info.st_dev):\(info.st_ino)",
            size: Int64(info.st_size),
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: modifiedNanoseconds)
    }
}

struct CostUsageClaudeReportMemoKey: Equatable, Sendable {
    let provider: UsageProvider
    let providerFilter: String
    let sinceKey: String
    let untilKey: String
    let scanSinceKey: String
    let scanUntilKey: String
    let timeZoneIdentifier: String
    let roots: [String]
    let cacheArtifactStamp: CostUsageClaudeFileStamp?
    let pricingArtifactStamp: CostUsageClaudeFileStamp?

    var scanConfiguration: ScanConfiguration {
        ScanConfiguration(
            provider: self.provider,
            providerFilter: self.providerFilter,
            timeZoneIdentifier: self.timeZoneIdentifier,
            roots: self.roots)
    }

    struct ScanConfiguration: Equatable, Sendable {
        let provider: UsageProvider
        let providerFilter: String
        let timeZoneIdentifier: String
        let roots: [String]
    }
}

final class CostUsageClaudeReportMemo: @unchecked Sendable {
    struct Entry {
        let sourceInventory: [String: CostUsageClaudeFileStamp]
        let reportKey: CostUsageClaudeReportMemoKey
        let report: CostUsageDailyReport
    }

    static let shared = CostUsageClaudeReportMemo()

    private struct StoredEntry {
        let entry: Entry
        let generation: UInt64
    }

    private let lock = NSLock()
    private let capacity = 8
    private var generation: UInt64 = 0
    private var entries: [String: StoredEntry] = [:]

    func entry(provider: UsageProvider, canonicalCachePath: String) -> Entry? {
        let key = Self.key(provider: provider, canonicalCachePath: canonicalCachePath)
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries[key]?.entry
    }

    func store(
        provider: UsageProvider,
        canonicalCachePath: String,
        sourceInventory: [String: CostUsageClaudeFileStamp],
        reportKey: CostUsageClaudeReportMemoKey,
        report: CostUsageDailyReport)
    {
        let key = Self.key(provider: provider, canonicalCachePath: canonicalCachePath)
        self.lock.lock()
        defer { self.lock.unlock() }
        self.generation &+= 1
        self.entries[key] = StoredEntry(
            entry: Entry(sourceInventory: sourceInventory, reportKey: reportKey, report: report),
            generation: self.generation)
        if self.entries.count > self.capacity,
           let oldest = self.entries.min(by: { $0.value.generation < $1.value.generation })?.key
        {
            self.entries.removeValue(forKey: oldest)
        }
    }

    #if DEBUG
    func evict(provider: UsageProvider, canonicalCachePath: String) {
        let key = Self.key(provider: provider, canonicalCachePath: canonicalCachePath)
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries.removeValue(forKey: key)
    }
    #endif

    private static func key(provider: UsageProvider, canonicalCachePath: String) -> String {
        "\(provider.rawValue)|\(canonicalCachePath)"
    }
}

#if DEBUG
extension CostUsageScanner {
    enum ClaudeScanWork: Sendable {
        case cacheDecode
        case transcriptParse
        case reconcile
        case cacheEncode
        case reprice
    }

    struct ClaudeScanWorkMetrics: Equatable, Sendable {
        var cacheDecodes = 0
        var transcriptParses = 0
        var reconciliations = 0
        var cacheEncodes = 0
        var repricedRows = 0
    }

    final class ClaudeScanWorkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var metrics = ClaudeScanWorkMetrics()

        func record(_ work: ClaudeScanWork) {
            self.lock.lock()
            defer { self.lock.unlock() }
            switch work {
            case .cacheDecode: self.metrics.cacheDecodes += 1
            case .transcriptParse: self.metrics.transcriptParses += 1
            case .reconcile: self.metrics.reconciliations += 1
            case .cacheEncode: self.metrics.cacheEncodes += 1
            case .reprice: self.metrics.repricedRows += 1
            }
        }

        func snapshot() -> ClaudeScanWorkMetrics {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.metrics
        }
    }

    @TaskLocal private static var claudeScanWorkRecorder: ClaudeScanWorkRecorder?

    static func withClaudeScanWorkRecorderForTesting<T>(
        _ recorder: ClaudeScanWorkRecorder,
        operation: () throws -> T) rethrows -> T
    {
        try self.$claudeScanWorkRecorder.withValue(recorder) {
            try operation()
        }
    }

    static func recordClaudeScanWork(_ work: ClaudeScanWork) {
        self.claudeScanWorkRecorder?.record(work)
    }

    static func evictClaudeReportMemoForTesting(provider: UsageProvider, cacheRoot: URL?) {
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let canonicalCachePath = cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
        CostUsageClaudeReportMemo.shared.evict(
            provider: provider,
            canonicalCachePath: canonicalCachePath)
    }
}
#endif

/// Claude and Vertex retain their small transcript cache. Codex deliberately has no route
/// through this JSON I/O boundary; its only persistence authority is `CostUsageStore`.
enum CostUsageClaudeCacheIO {
    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    // Provider-specific by design: Claude/Vertex cost caching still uses the legacy JSON artifact pending its own
    // migration (see #2760).

    static func cacheFileURL(provider: UsageProvider, cacheRoot: URL? = nil) -> URL {
        precondition(provider == .claude || provider == .vertexai)
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-v6.json", isDirectory: false)
    }

    static func load(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        calendar: Calendar? = nil) -> CostUsageCache
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url) else { return CostUsageCache() }
        #if DEBUG
        CostUsageScanner.recordClaudeScanWork(.cacheDecode)
        #endif
        guard let cache = try? JSONDecoder().decode(CostUsageCache.self, from: data),
              cache.version == 1
        else { return CostUsageCache() }
        if let calendar, cache.timeZoneIdentifier != calendar.timeZone.identifier {
            return CostUsageCache()
        }
        return cache
    }

    static func save(
        provider: UsageProvider,
        cache: CostUsageCache,
        cacheRoot: URL? = nil,
        calendar: Calendar = .current,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CostUsageClaudeFileStamp?
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        var cache = cache
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        #if DEBUG
        CostUsageScanner.recordClaudeScanWork(.cacheEncode)
        #endif
        guard let data = try? JSONEncoder().encode(cache) else { return nil }
        try checkCancellation?()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".claude-cache-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL)
            guard let stamp = CostUsageClaudeFileStamp.read(at: temporaryURL),
                  rename(temporaryURL.path, url.path) == 0
            else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return nil
            }
            return stamp
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        }
    }
}
