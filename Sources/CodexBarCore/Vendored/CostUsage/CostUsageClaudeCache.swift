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
        let key = "\(provider.rawValue)|\(canonicalCachePath)"
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
        let key = "\(provider.rawValue)|\(canonicalCachePath)"
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
        let key = "\(provider.rawValue)|\(canonicalCachePath)"
        self.lock.withLock { self.entries.removeAll { $0.key == key } }
    }

    #endif

    private func installUnlocked(key: String, entry: Entry) {
        self.entries.removeAll { $0.key == key }
        self.entries.append((key: key, entry: entry))
        if self.entries.count > self.capacity { self.entries.removeFirst() }
    }

    static func reportMemoFileURL(cacheFileURL: URL) -> URL {
        cacheFileURL.deletingPathExtension().appendingPathExtension("report-memo.json")
    }

    private static func loadPersisted(canonicalCachePath: String) -> Entry? {
        let url = Self.reportMemoFileURL(cacheFileURL: URL(fileURLWithPath: canonicalCachePath))
        guard let loaded = try? CostUsageClaudeFragments.shared.load(at: url, legacy: { data in
            var envelope = try JSONDecoder().decode(PersistedEnvelope.self, from: data)
            let inventory = envelope.sourceInventory
            envelope.sourceInventory = [:]
            return (envelope, inventory)
        }) else { return nil }
        var envelope: PersistedEnvelope = loaded.0
        envelope.sourceInventory = loaded.1
        guard envelope.version == Self.persistedVersion,
              envelope.reportSemanticsVersion == Self.reportSemanticsVersion,
              Self.hasValidIncompleteCounts(envelope.report)
        else { return nil }
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
            sourceInventory: [:],
            reportKey: entry.reportKey,
            report: entry.report,
            hourly: entry.report.hourly.map(CostUsageCodexPreviousReport.HourlyEntry.init),
            quotaSlices: QuotaSlices(values: entry.report.quotaSlices),
            hasWindowScopedRows: entry.hasWindowScopedRows)
        _ = try? CostUsageClaudeFragments.shared.save(
            header: envelope, values: entry.sourceInventory, at: url)
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

    final class File: Codable, Equatable {
        let usage: CostUsageFileUsage?
        let sourceID: String?
        let sourceKey: String?
        private let metadata: Data
        private enum CodingKeys: CodingKey { case usage, sourceID, sourceKey }

        init(usage: CostUsageFileUsage?, sourceID: String?, sourceKey: String?, encoder: JSONEncoder) throws {
            self.usage = usage
            self.sourceID = sourceID
            self.sourceKey = sourceKey
            var metadata = usage
            metadata?.claudeRows = nil
            self.metadata = try encoder.encode(metadata)
        }

        convenience init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try self.init(
                usage: container.decodeIfPresent(CostUsageFileUsage.self, forKey: .usage),
                sourceID: container.decodeIfPresent(String.self, forKey: .sourceID),
                sourceKey: container.decodeIfPresent(String.self, forKey: .sourceKey),
                encoder: encoder)
        }

        static func == (lhs: File, rhs: File) -> Bool {
            if lhs === rhs { return true }
            guard lhs.metadata == rhs.metadata, self.sameString(lhs.sourceID, rhs.sourceID),
                  self.sameString(lhs.sourceKey, rhs.sourceKey) else { return false }
            let left = lhs.usage?.claudeRows, right = rhs.usage?.claudeRows
            guard let left, let right else { return left == nil && right == nil }
            guard left.count == right.count else { return false }
            if left.withUnsafeBufferPointer({ buffer in
                right.withUnsafeBufferPointer { buffer.baseAddress == $0.baseAddress }
            }) { return true }
            return zip(left, right).allSatisfy { a, b in
                a == b && Self.sameString(a.dayKey, b.dayKey) && Self.sameString(a.model, b.model)
                    && Self.sameString(a.sessionId, b.sessionId) && Self.sameString(a.messageId, b.messageId)
                    && Self.sameString(a.requestId, b.requestId)
            }
        }

        private static func sameString(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs, let rhs else { return lhs == nil && rhs == nil }
            return lhs.utf8.elementsEqual(rhs.utf8)
        }
    }

    func split() throws -> (Self, [String: File]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var files: [String: File] = .init(minimumCapacity: self.usage.files.count)
        for path in Array(self.usage.files.keys) + self.sourceFileIDs.keys.filter({ self.usage.files[$0] == nil }) {
            let sourceKey = self.sourceFileIDs.index(forKey: path).map { self.sourceFileIDs[$0].key }
            let file = try File(
                usage: self.usage.files[path],
                sourceID: self.sourceFileIDs[path],
                sourceKey: sourceKey,
                encoder: encoder)
            files[path] = self.fileRecords[path].flatMap { $0 == file ? $0 : nil } ?? file
        }
        var header = self
        header.usage.files = [:]
        header.sourceFileIDs = [:]
        header.fileRecords = [:]
        header.contentID = self.contentID
        return (header, files)
    }

    mutating func join(_ files: [String: File]) {
        let contentID = self.contentID
        self.usage.files = files.reduce(into: .init(minimumCapacity: files.count)) { $0[$1.key] = $1.value.usage }
        self.sourceFileIDs = files.reduce(into: .init(minimumCapacity: files.count)) { identities, entry in
            if let identity = entry.value.sourceID { identities[entry.value.sourceKey ?? entry.key] = identity }
        }
        self.fileRecords = files
        self.contentID = contentID
    }

    private var fileRecords: [String: File] = [:]
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

    #if DEBUG
    @TaskLocal static var readForTesting: (@Sendable (URL, Data.ReadingOptions) -> Data?)?

    #endif

    // Provider-specific by design: Claude/Vertex share shards but keep separate artifacts and report windows.

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
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let loaded = try? CostUsageClaudeFragments.shared.load(at: key, legacy: { data in
            let decoder = JSONDecoder()
            decoder.userInfo[CostUsageRowStringPool.key] = CostUsageRowStringPool()
            return try decoder.decode(CostUsageClaudeCache.self, from: data).split()
        }) else { return CostUsageClaudeCache() }
        var cache: CostUsageClaudeCache = loaded.0
        cache.join(loaded.1)
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
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        try checkCancellation?()
        if let stamp = CostUsageClaudeFragments.shared.currentStamp(contentID: cache.contentID, at: key) {
            return stamp
        }
        #if DEBUG
        CostUsageScanner.recordClaudeScanWork(.cacheEncode)
        #endif
        let (header, files) = try cache.split()
        return try CostUsageClaudeFragments.shared.save(
            header: header, values: files, at: key, contentID: cache.contentID, checkCancellation: checkCancellation)
    }

    static func read(at url: URL, options: Data.ReadingOptions = []) -> Data? {
        #if DEBUG
        CostUsageScanner.recordClaudeScanWork(.artifactRead)
        if let readForTesting { return readForTesting(url, options) }
        #endif
        return try? Data(contentsOf: url, options: options)
    }
}
