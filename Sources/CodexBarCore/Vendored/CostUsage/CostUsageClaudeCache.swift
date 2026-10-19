import Crypto
import Foundation

struct CostUsageClaudeFileStamp: Equatable, Sendable, Codable {
    let fileID: String
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    var mtimeUnixMs: Int64 {
        self.modifiedSeconds * 1000 + self.modifiedNanoseconds / 1_000_000
    }

    static func read(at url: URL) -> Self? {
        try? self.readIfPresent(at: url)
    }

    /// Returns nil for a missing path, but throws when an existing source cannot be stat'ed.
    static func readIfPresent(at url: URL) throws -> Self? {
        var info = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        #if os(Linux)
        let modifiedTime = info.st_mtim
        #else
        let modifiedTime = info.st_mtimespec
        #endif
        return Self(
            fileID: "\(info.st_dev):\(info.st_ino)",
            size: Int64(info.st_size),
            modifiedSeconds: Int64(modifiedTime.tv_sec),
            modifiedNanoseconds: Int64(modifiedTime.tv_nsec))
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(ENOENT) || error.code == Int(ENOTDIR) }
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
        {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
        return self.isMissingFileError(underlying)
    }
}

struct CostUsageClaudeReportMemoKey: Equatable, Sendable, Codable {
    let provider: UsageProvider
    let providerFilter: String
    let sinceKey: String
    let untilKey: String
    let scanSinceKey: String
    let scanUntilKey: String
    let timeZoneIdentifier: String
    let roots: [String]
    var cacheArtifactStamp: CostUsageClaudeFileStamp?
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
        /// Established by a full rebuild or continuation of certified rows for this memo's scan window.
        let hasWindowScopedRows: Bool

        func certifiesWindow(reportKey: CostUsageClaudeReportMemoKey, cache: CostUsageCache) -> Bool {
            self.hasWindowScopedRows
                && self.reportKey.cacheArtifactStamp == reportKey.cacheArtifactStamp
                && self.reportKey.scanConfiguration == reportKey.scanConfiguration
                && self.reportKey.scanSinceKey == reportKey.scanSinceKey
                && self.reportKey.scanUntilKey == reportKey.scanUntilKey
                && cache.scanSinceKey == reportKey.scanSinceKey
                && cache.scanUntilKey == reportKey.scanUntilKey
        }
    }

    #if DEBUG
    @TaskLocal static var shared = CostUsageClaudeReportMemo()
    @TaskLocal static var observeWireEntriesForTesting: (@Sendable (Int) -> Void)?
    #else
    static let shared = CostUsageClaudeReportMemo()
    #endif
    static let persistedVersion = 1
    /// Bump when bundled pricing, model aliases, or daily-report aggregation changes without new artifact stamps.
    static let reportSemanticsVersion = 6

    private struct PersistedEnvelope: Codable {
        var version: Int
        var reportSemanticsVersion: Int
        var sourceInventory: [String: CostUsageClaudeFileStamp]
        var reportKey: CostUsageClaudeReportMemoKey
        var report: CostUsageDailyReport
        var hourly: [CostUsageCodexPreviousReport.HourlyEntry]?
        var quotaSlices: QuotaSlices?
        var hasWindowScopedRows: Bool?
    }

    private struct QuotaSlices: Codable {
        let values: [CostUsageTimedEntry]

        init(values: [CostUsageTimedEntry]) {
            self.values = values
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var values: [CostUsageTimedEntry] = []
            values.reserveCapacity(container.count ?? 0)
            while !container.isAtEnd {
                let wire = try container.decode(CostUsageCodexPreviousReport.QuotaSlice.self)
                #if DEBUG
                CostUsageClaudeReportMemo.observeWireEntriesForTesting?(1)
                #endif
                values.append(wire.timedValue)
            }
            self.values = values
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            for value in self.values {
                let wire = CostUsageCodexPreviousReport.QuotaSlice(value)
                #if DEBUG
                CostUsageClaudeReportMemo.observeWireEntriesForTesting?(1)
                #endif
                try container.encode(wire)
            }
        }
    }

    private let lock = NSLock()
    private let capacity = 8
    private var entries: [(key: String, entry: Entry)] = []

    func entry(provider: UsageProvider, canonicalCachePath: String) -> Entry? {
        let key = Self.key(provider: provider, canonicalCachePath: canonicalCachePath)
        if let memory = self.lock.withLock({ self.entries.first(where: { $0.key == key })?.entry }) {
            return memory
        }
        guard let persisted = Self.loadPersisted(canonicalCachePath: canonicalCachePath) else { return nil }
        return self.lock.withLock {
            if let memory = self.entries.first(where: { $0.key == key })?.entry { return memory }
            self.installUnlocked(key: key, entry: persisted)
            return persisted
        }
    }

    func store(
        provider: UsageProvider,
        canonicalCachePath: String,
        sourceInventory: [String: CostUsageClaudeFileStamp],
        reportKey: CostUsageClaudeReportMemoKey,
        report: CostUsageDailyReport,
        hasWindowScopedRows: Bool = false)
    {
        let key = Self.key(provider: provider, canonicalCachePath: canonicalCachePath)
        let entry = Entry(
            sourceInventory: sourceInventory,
            reportKey: reportKey,
            report: report,
            hasWindowScopedRows: hasWindowScopedRows)
        self.lock.withLock { self.installUnlocked(key: key, entry: entry) }
        Self.persist(entry, canonicalCachePath: canonicalCachePath)
    }

    #if DEBUG
    func evict(provider: UsageProvider, canonicalCachePath: String) {
        let key = Self.key(provider: provider, canonicalCachePath: canonicalCachePath)
        self.lock.withLock { self.entries.removeAll { $0.key == key } }
    }

    #endif

    private func installUnlocked(key: String, entry: Entry) {
        self.entries.removeAll { $0.key == key }
        self.entries.append((key: key, entry: entry))
        if self.entries.count > self.capacity { self.entries.removeFirst() }
    }

    private static func key(provider: UsageProvider, canonicalCachePath: String) -> String {
        "\(provider.rawValue)|\(canonicalCachePath)"
    }

    static func reportMemoFileURL(cacheFileURL: URL) -> URL {
        let stem = cacheFileURL.deletingPathExtension().lastPathComponent
        return cacheFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem).report-memo.json", isDirectory: false)
    }

    private static func loadPersisted(canonicalCachePath: String) -> Entry? {
        let url = Self.reportMemoFileURL(cacheFileURL: URL(fileURLWithPath: canonicalCachePath))
        let stamp = CostUsageClaudeFileStamp.read(at: url)
        #if DEBUG
        CostUsageScanner.recordClaudeScanWork(.artifactRead)
        #endif
        // Writers replace by rename; the mapped inode stays immutable and is released after decoding/hashing.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let envelope = try? JSONDecoder().decode(PersistedEnvelope.self, from: data),
              envelope.version == Self.persistedVersion,
              envelope.reportSemanticsVersion == Self.reportSemanticsVersion,
              Self.hasValidIncompleteCounts(envelope.report)
        else { return nil }
        CostUsageClaudeCacheIO.remember(data: data, at: url, stamp: stamp)
        return Entry(
            sourceInventory: envelope.sourceInventory,
            reportKey: envelope.reportKey,
            report: CostUsageDailyReport(
                data: envelope.report.data,
                summary: envelope.report.summary,
                hourly: (envelope.hourly ?? []).map(\.hourlyValue),
                quotaSlices: envelope.quotaSlices?.values ?? []),
            hasWindowScopedRows: envelope.hasWindowScopedRows == true)
    }

    private static func hasValidIncompleteCounts(_ report: CostUsageDailyReport) -> Bool {
        let counts = report.data.flatMap { $0.modelBreakdowns ?? [] }.compactMap(\.incompleteRequestCount)
        return counts.allSatisfy { $0 >= 0 } && CheckedSum.integers(counts) != nil
    }

    private static func persist(_ entry: Entry, canonicalCachePath: String) {
        let url = Self.reportMemoFileURL(cacheFileURL: URL(fileURLWithPath: canonicalCachePath))
        let envelope = PersistedEnvelope(
            version: Self.persistedVersion,
            reportSemanticsVersion: Self.reportSemanticsVersion,
            sourceInventory: entry.sourceInventory,
            reportKey: entry.reportKey,
            report: entry.report,
            hourly: entry.report.hourly.map(CostUsageCodexPreviousReport.HourlyEntry.init),
            quotaSlices: QuotaSlices(values: entry.report.quotaSlices),
            hasWindowScopedRows: entry.hasWindowScopedRows)
        _ = try? CostUsageClaudeCacheIO.write(envelope, to: url)
    }
}

#if DEBUG
extension CostUsageScanner {
    enum ClaudeScanWork: Sendable {
        case cacheDecode
        case transcriptParse(startOffset: Int64)
        case reconcile
        case cacheEncode
        case fragmentEncode
        case fragmentFallback
        case artifactRead
        case artifactWrite
        case reprice
        case normalizationCacheMiss
        case vertexMetadataWalk
        case claudeLineDecode
        case claudeCostCalculation
        case catalogModelLookup(found: Bool)
    }

    @TaskLocal static var observeClaudeScanWorkForTesting: (@Sendable (ClaudeScanWork) -> Void)?

    static func recordClaudeScanWork(_ work: ClaudeScanWork) {
        self.observeClaudeScanWorkForTesting?(work)
    }
}
#endif

struct CostUsageClaudeCache: Codable {
    var usage = CostUsageCache() {
        didSet { self.contentID = UUID() }
    }

    var sourceFileIDs: [String: String] = [:] {
        didSet { self.contentID = UUID() }
    }

    private(set) var contentID = UUID() // String equality cannot establish byte-identical JSON.

    private enum CodingKeys: String, CodingKey { case sourceFileIDs }

    init() {}

    init(from decoder: any Decoder) throws {
        self.usage = try CostUsageCache(from: decoder)
        self.sourceFileIDs = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent([String: String].self, forKey: .sourceFileIDs) ?? [:]
    }

    func encode(to encoder: any Encoder) throws {
        try self.usage.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sourceFileIDs, forKey: .sourceFileIDs)
    }
}

/// Avoid repeating long field names for every retained response.
extension CostUsageScanner.ClaudeUsageRow {
    enum CodingKeys: String, CodingKey {
        case dayKey = "d"
        case model = "m"
        case sessionId = "s"
        case messageId = "i"
        case requestId = "r"
        case timestampUnixMs = "t"
        case isSidechain = "b"
        case pathRole = "p"
        case input = "in"
        case cacheRead = "cr"
        case cacheCreate = "cc"
        case cacheCreate1h = "ch"
        case output = "out"
        case costNanos = "c"
        case costPriced = "priced"
        case isIncomplete = "partial"
    }
}

/// Claude and Vertex retain their transcript cache. Codex deliberately has no route
/// through this JSON I/O boundary; its only persistence authority is `CostUsageStore`.
enum CostUsageClaudeCacheIO {
    /// Compact row keys; older artifacts rebuild from their source transcripts.
    private static let schemaVersion = 4

    /// Decoded rows may be evicted under memory pressure; eight small persistence identities survive independently.
    /// The scanner still validates source scope and reprices rows.
    final class ArtifactMemo: @unchecked Sendable {
        final class Entry {
            let stamp: CostUsageClaudeFileStamp
            let cache: CostUsageClaudeCache

            init(stamp: CostUsageClaudeFileStamp, cache: CostUsageClaudeCache) {
                self.stamp = stamp
                self.cache = cache
            }
        }

        #if DEBUG
        @TaskLocal static var shared = ArtifactMemo()
        #else
        static let shared = ArtifactMemo()
        #endif
        let entries = NSCache<NSURL, Entry>()

        private let lock = NSLock()
        private typealias Identity = (stamp: CostUsageClaudeFileStamp, digest: SHA256.Digest, contentID: UUID?)
        private var identities: [(url: URL, value: Identity)] = []

        func identity(at url: URL) -> (stamp: CostUsageClaudeFileStamp, digest: SHA256.Digest, contentID: UUID?)? {
            self.lock.withLock { self.identities.last(where: { $0.url == url })?.value }
        }

        func remember(at url: URL, stamp: CostUsageClaudeFileStamp, digest: SHA256.Digest, contentID: UUID?) {
            self.lock.withLock {
                self.identities.removeAll { $0.url == url }
                self.identities.append((url, (stamp, digest, contentID)))
                if self.identities.count > 8 { self.identities.removeFirst() }
            }
        }

        init() {
            self.entries.countLimit = 4
        }
    }

    #if DEBUG
    @TaskLocal static var readForTesting: (@Sendable (URL, Data.ReadingOptions) -> Data?)?

    #endif

    // Provider-specific by design: Claude/Vertex cost caching still uses the legacy JSON artifact pending its own
    // migration (see #2760).

    static func cacheFileURL(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        reportContext: CostUsageReportContext = .regular) -> URL
    {
        precondition(provider == .claude || provider == .vertexai)
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        // Parsing filters dates before selecting duplicate responses, so independent report windows
        // need their own rows.
        let suffix = reportContext == .spendDashboard ? "-history" : ""
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)\(suffix)-v6.json", isDirectory: false)
    }

    static func load(
        provider: UsageProvider,
        cacheRoot: URL? = nil,
        reportContext: CostUsageReportContext = .regular,
        calendar: Calendar? = nil) -> CostUsageClaudeCache
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot, reportContext: reportContext)
        let key = url.standardizedFileURL.resolvingSymlinksInPath() as NSURL
        let stamp = CostUsageClaudeFileStamp.read(at: url)
        let cache: CostUsageClaudeCache
        if let stamp, let memoized = ArtifactMemo.shared.entries.object(forKey: key), memoized.stamp == stamp {
            cache = memoized.cache
        } else {
            // Replacement uses rename; the decoded cache owns its values, not the mapped old inode.
            guard let data = self.read(at: url, options: .mappedIfSafe) else { return CostUsageClaudeCache() }
            #if DEBUG
            CostUsageScanner.recordClaudeScanWork(.cacheDecode)
            #endif
            let decoder = JSONDecoder()
            decoder.userInfo[CostUsageRowStringPool.key] = CostUsageRowStringPool()
            guard let decoded = try? decoder.decode(CostUsageClaudeCache.self, from: data) else {
                return CostUsageClaudeCache()
            }
            cache = decoded
            // A concurrent replacement must fall through to a fresh decode next time.
            if let stamp, CostUsageClaudeFileStamp.read(at: url) == stamp {
                self.remember(data: data, at: url, stamp: stamp, contentID: cache.contentID)
                ArtifactMemo.shared.entries.setObject(ArtifactMemo.Entry(stamp: stamp, cache: cache), forKey: key)
            }
        }
        guard cache.usage.version == self.schemaVersion,
              calendar == nil || cache.usage.timeZoneIdentifier == calendar?.timeZone.identifier
        else { return CostUsageClaudeCache() }
        return cache
    }

    static func save(
        provider: UsageProvider,
        cache: CostUsageClaudeCache,
        cacheRoot: URL? = nil,
        reportContext: CostUsageReportContext = .regular,
        calendar: Calendar = .current,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CostUsageClaudeFileStamp?
    {
        let url = self.cacheFileURL(provider: provider, cacheRoot: cacheRoot, reportContext: reportContext)
        var cache = cache
        let timeZoneID = calendar.timeZone.identifier
        if cache.usage.version != self.schemaVersion { cache.usage.version = self.schemaVersion }
        if cache.usage.timeZoneIdentifier?.utf8.elementsEqual(timeZoneID.utf8) != true {
            cache.usage.timeZoneIdentifier = timeZoneID
        }
        let key = url.standardizedFileURL.resolvingSymlinksInPath() as NSURL
        let stamp = try self.write(cache, to: url, contentID: cache.contentID, checkCancellation: checkCancellation)
        if let stamp, CostUsageClaudeFileStamp.read(at: url) == stamp {
            ArtifactMemo.shared.entries.setObject(ArtifactMemo.Entry(stamp: stamp, cache: cache), forKey: key)
        }
        return stamp
    }

    fileprivate static func write(
        _ value: some Encodable,
        to url: URL,
        contentID: UUID? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CostUsageClaudeFileStamp?
    {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        try checkCancellation?()
        let identity = ArtifactMemo.shared.identity(at: key)
        if let identity, let contentID, identity.contentID == contentID,
           CostUsageClaudeFileStamp.read(at: url) == identity.stamp { return identity.stamp }
        #if DEBUG
        if contentID != nil { CostUsageScanner.recordClaudeScanWork(.cacheEncode) }
        #endif
        let encoder = JSONEncoder()
        // Stable fingerprints preserve stamps when a rescan rebuilds byte-identical content with a new UUID.
        encoder.outputFormatting = [.sortedKeys]
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".claude-cache-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let output = CostUsageClaudeArtifactWriter(temporaryURL: temporaryURL, replacing: url) else {
            return nil
        }
        var hasher = SHA256()
        func append(_ data: Data?) throws {
            guard let data else {
                try output.reset()
                hasher = SHA256()
                return
            }
            _ = try output.append(data)
            hasher.update(data: data)
        }
        func commit() throws -> CostUsageClaudeFileStamp? {
            try checkCancellation?()
            let digest = hasher.finalize()
            if let identity, identity.digest == digest, CostUsageClaudeFileStamp.read(at: url) == identity.stamp {
                ArtifactMemo.shared.remember(at: key, stamp: identity.stamp, digest: digest, contentID: contentID)
                return identity.stamp
            }
            try output.finish()
            guard let stamp = CostUsageClaudeFileStamp.read(at: temporaryURL),
                  rename(temporaryURL.path, url.path) == 0 else { return nil }
            ArtifactMemo.shared.remember(at: key, stamp: stamp, digest: digest, contentID: contentID)
            #if DEBUG
            CostUsageScanner.recordClaudeScanWork(.artifactWrite)
            #endif
            return stamp
        }
        if let cache = value as? CostUsageClaudeCache {
            return try CostUsageClaudeFragments.shared.write(
                cache, at: key, encoder: encoder, output: append, commit: commit)
        }
        guard let data = try? encoder.encode(value), (try? append(data)) != nil else { return nil }
        return try commit()
    }

    fileprivate static func read(at url: URL, options: Data.ReadingOptions = []) -> Data? {
        #if DEBUG
        CostUsageScanner.recordClaudeScanWork(.artifactRead)
        if let readForTesting { return readForTesting(url, options) }
        #endif
        return try? Data(contentsOf: url, options: options)
    }

    fileprivate static func remember(
        data: Data,
        at url: URL,
        stamp: CostUsageClaudeFileStamp?,
        contentID: UUID? = nil)
    {
        guard let stamp, CostUsageClaudeFileStamp.read(at: url) == stamp else { return }
        ArtifactMemo.shared.remember(
            at: url.standardizedFileURL.resolvingSymlinksInPath(),
            stamp: stamp,
            digest: SHA256.hash(data: data),
            contentID: contentID)
    }
}
