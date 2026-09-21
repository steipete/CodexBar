import CoreFoundation
import Foundation

private final class PiSessionISO8601FormatterBox: @unchecked Sendable {
    let lock = NSLock()
    let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// swiftlint:disable:next type_body_length
enum PiSessionCostScanner {
    @TaskLocal static var sessionParseObserverForTesting: (@Sendable () -> Void)?

    struct Options {
        var piSessionsRoot: URL?
        var ompSessionsRoot: URL?
        var cacheRoot: URL?
        var calendar: Calendar
        var refreshMinIntervalSeconds: TimeInterval = 60
        var forceRescan: Bool = false
        var environment: [String: String]
        var workingDirectory: URL?
        var workingDirectories: [URL]
        var processContexts: [PiSessionProcessContext]

        init(
            piSessionsRoot: URL? = nil,
            ompSessionsRoot: URL? = nil,
            cacheRoot: URL? = nil,
            calendar: Calendar = .current,
            refreshMinIntervalSeconds: TimeInterval = 60,
            forceRescan: Bool = false,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            workingDirectory: URL? = nil,
            workingDirectories: [URL] = [],
            processContexts: [PiSessionProcessContext] = [])
        {
            self.piSessionsRoot = piSessionsRoot
            self.ompSessionsRoot = ompSessionsRoot
            self.cacheRoot = cacheRoot
            self.calendar = calendar
            self.refreshMinIntervalSeconds = refreshMinIntervalSeconds
            self.forceRescan = forceRescan
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.workingDirectories = workingDirectories
            self.processContexts = processContexts
        }
    }

    private struct ParseResult {
        let contributions: [String: [String: [String: PiPackedUsage]]]
        let unkeyedContributions: [String: [String: [String: PiPackedUsage]]]
        let entryUsages: [String: PiSessionEntryUsage]
        let parsedBytes: Int64
        let sessionID: String?
        let lastModelContext: PiModelContext?
        let isComplete: Bool
        let unsupportedAssistantDayKeys: Set<String>
        let hasUndatedUnsupportedAssistant: Bool
    }

    private struct SessionFileCandidate {
        let url: URL
        let rootIndex: Int
    }

    private struct SessionRoot {
        let url: URL
        let missingIsKnownEmpty: Bool
        let resolutionIsComplete: Bool
        let preserveAfterProcessExit: Bool
        let retentionKeys: Set<String>
    }

    private struct AssistantIdentity {
        let provider: UsageProvider
        let modelName: String
    }

    private struct ModelsDevPricingContext {
        let catalog: ModelsDevCatalog?
        let cacheRoot: URL?
        let pricingKey: String
    }

    private struct ScanContext {
        let range: CostUsageScanner.CostUsageDayRange
        let forceRescan: Bool
        let pricingContext: ModelsDevPricingContext
        let checkCancellation: CostUsageScanner.CancellationCheck?
    }

    static let costScale = 1_000_000_000.0
    /// Bump for Pi-only cost formula changes not represented by the parser or pricing fingerprints.
    private static let costFormulaVersion = 2
    private static let maxLineBytes = 16 * 1024 * 1024
    private static let sessionStartFilenameRegex = try? NSRegularExpression(
        pattern: "^(\\d{4}-\\d{2}-\\d{2})T(\\d{2})-(\\d{2})-(\\d{2})-(\\d{3})Z_")
    private static let isoFormatterBox = PiSessionISO8601FormatterBox()

    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        (
            try? self.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: nil)) ?? CostUsageDailyReport(data: [], summary: nil)
    }

    struct DailyReportResult {
        let report: CostUsageDailyReport
        let isComplete: Bool
        let lastScanAt: Date?
        /// The scope represented by `report`, which may be the prior cache scope when a
        /// newly requested root set could not be inspected completely.
        let scopeFingerprint: String?
    }

    static func loadDailyReportCancellable(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> CostUsageDailyReport
    {
        try self.loadDailyReportResultCancellable(
            provider: provider,
            since: since,
            until: until,
            now: now,
            options: options,
            checkCancellation: checkCancellation).report
    }

    static func loadDailyReportResultCancellable(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> DailyReportResult
    {
        // Provider-specific by design: Pi records only OpenAI Codex and Anthropic sessions with distinct pricing.
        guard provider == .codex || provider == .claude || provider == .pi else {
            return DailyReportResult(
                report: CostUsageDailyReport(data: [], summary: nil),
                isComplete: true,
                lastScanAt: nil,
                scopeFingerprint: nil)
        }

        let range = CostUsageScanner.CostUsageDayRange(
            since: since,
            until: until,
            calendar: options.calendar)
        var cache = PiSessionCostCacheIO.load(cacheRoot: options.cacheRoot)
        if cache.timeZoneIdentifier != range.calendar.timeZone.identifier {
            cache = PiSessionCostCache()
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let pricingContext = self.pricingContext(now: now, cacheRoot: options.cacheRoot)
        let roots = self.defaultSessionRoots(
            options: options,
            previousSessionRootsFingerprint: cache.sessionRootsFingerprint)
        let sessionRootsFingerprint = self.sessionRootsFingerprint(roots)
        let windowExpanded = self.requestedWindowExpandsCache(range: range, cache: cache)
        let pricingChanged = cache.pricingKey != pricingContext.pricingKey
        let sessionRootsChanged = cache.sessionRootsFingerprint != sessionRootsFingerprint
        let invalidCache = cache.files.values.contains { $0.fileIdentity == nil }
            || self.checkedReports(cache: cache, range: range) == nil
        let cacheBeforeScan = cache
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || pricingChanged
            || sessionRootsChanged
            || invalidCache
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs
        var scanIsComplete = roots.allSatisfy(\.resolutionIsComplete)

        if shouldRefresh {
            try checkCancellation?()
            let startCutoff = self.dateFromDayKey(range.scanSinceKey, calendar: range.calendar) ?? since
            var files: [SessionFileCandidate] = []
            var seenFilePaths = Set<String>()
            for (rootIndex, root) in roots.enumerated() {
                guard root.resolutionIsComplete else { continue }
                let result = self.listPiSessionFiles(
                    root: root.url,
                    startCutoffLocal: startCutoff,
                    calendar: range.calendar,
                    missingIsKnownEmpty: root.missingIsKnownEmpty)
                scanIsComplete = scanIsComplete && result.isComplete
                for url in result.files {
                    let canonicalURL = self.canonicalSessionFileURL(url)
                    guard seenFilePaths.insert(canonicalURL.path).inserted else { continue }
                    files.append(SessionFileCandidate(url: canonicalURL, rootIndex: rootIndex))
                }
            }
            files.sort { lhs, rhs in
                lhs.rootIndex == rhs.rootIndex
                    ? lhs.url.path < rhs.url.path
                    : lhs.rootIndex < rhs.rootIndex
            }
            let filePathsInScan = Set(files.map(\.url.path))

            for file in files {
                let fileIsComplete = try self.scanPiSessionFile(
                    fileURL: file.url,
                    cache: &cache,
                    context: ScanContext(
                        range: range,
                        forceRescan: options.forceRescan || windowExpanded || pricingChanged || invalidCache,
                        pricingContext: pricingContext,
                        checkCancellation: checkCancellation))
                scanIsComplete = scanIsComplete && fileIsComplete
            }
            try checkCancellation?()

            if scanIsComplete {
                for key in cache.files.keys where !filePathsInScan.contains(key) {
                    cache.files.removeValue(forKey: key)
                }
            }

            if scanIsComplete {
                if try !self.rebuildDailyUsage(cache: &cache, files: files, checkCancellation: checkCancellation) {
                    cache = cacheBeforeScan
                    scanIsComplete = false
                }
            } else if sessionRootsChanged || pricingChanged {
                // Scope and pricing changes require one complete reparse. Keep the previous
                // report intact rather than mixing roots or catalog versions after a failure.
                cache = cacheBeforeScan
            } else {
                // Keep cached files from roots that could not be inspected. Rebuilding from only the
                // visible roots would silently discard their usage and turn an I/O failure into zero.
                let visiblePaths = Set(files.map(\.url.path))
                let preservedFiles = cache.files.keys
                    .filter { !visiblePaths.contains($0) }
                    .map { SessionFileCandidate(url: URL(fileURLWithPath: $0), rootIndex: Int.max) }
                if try !self.rebuildDailyUsage(
                    cache: &cache,
                    files: files + preservedFiles,
                    checkCancellation: checkCancellation)
                {
                    cache = cacheBeforeScan
                }
            }
        }

        if !shouldRefresh {
            scanIsComplete = self.cachedSourceFilesAreCurrent(cache: cache, roots: roots, calendar: options.calendar)
        }

        var reports = self.checkedReports(cache: cache, range: range)
        if reports == nil {
            cache = cacheBeforeScan
            scanIsComplete = false
            reports = self.checkedReports(cache: cache, range: range)
        }
        guard let reports else {
            return DailyReportResult(
                report: CostUsageDailyReport(data: [], summary: nil),
                isComplete: false,
                lastScanAt: nil,
                scopeFingerprint: nil)
        }
        // Validate all model/day/range sums before committing the candidate or advancing its age.
        if shouldRefresh, scanIsComplete {
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.pricingKey = pricingContext.pricingKey
            cache.sessionRootsFingerprint = sessionRootsFingerprint
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            PiSessionCostCacheIO.save(cache: cache, cacheRoot: options.cacheRoot, calendar: range.calendar)
        }
        // Provider-specific by design: the Pi provider aggregates its Codex and Claude-priced local sessions.
        let lastScanAt = cache.lastScanUnixMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)
            : nil
        if provider == .pi {
            return DailyReportResult(
                report: CostUsageDailyReport.merged([reports.codex, reports.claude], calendar: range.calendar),
                isComplete: scanIsComplete && !self.hasUnsupportedHistory(cache: cache, range: range),
                lastScanAt: lastScanAt,
                scopeFingerprint: cache.sessionRootsFingerprint)
        }
        return DailyReportResult(
            report: provider == .codex ? reports.codex : reports.claude,
            isComplete: scanIsComplete,
            lastScanAt: lastScanAt,
            scopeFingerprint: cache.sessionRootsFingerprint)
    }

    struct CachedDailyReportResult {
        let report: CostUsageDailyReport
        let lastScanAt: Date?
        let scopeFingerprint: String?
        let isComplete: Bool
    }

    static func loadCachedDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        cacheRoot: URL? = nil,
        calendar: Calendar = .current) -> CostUsageDailyReport?
    {
        self.loadCachedDailyReportResult(
            provider: provider,
            since: since,
            until: until,
            now: now,
            cacheRoot: cacheRoot,
            calendar: calendar)?.report
    }

    static func loadCachedDailyReportResult(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        cacheRoot: URL? = nil,
        calendar: Calendar = .current,
        options: Options? = nil,
        allowEstablishedEmpty: Bool = false) -> CachedDailyReportResult?
    {
        // Provider-specific by design: cached Pi history is the merged Codex/Claude report above.
        guard provider == .codex || provider == .claude || provider == .pi else { return nil }

        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until, calendar: calendar)
        let cache = PiSessionCostCacheIO.load(cacheRoot: cacheRoot)
        guard cache.timeZoneIdentifier == range.calendar.timeZone.identifier else { return nil }
        guard cache.files.values.allSatisfy({ $0.fileIdentity != nil }) else { return nil }
        var sourcesAreComplete = false
        if let options {
            let expectedRoots = self.defaultSessionRoots(
                options: options,
                previousSessionRootsFingerprint: cache.sessionRootsFingerprint)
            guard self.sessionRootsFingerprint(expectedRoots) == cache.sessionRootsFingerprint else { return nil }
            sourcesAreComplete = self.cachedSourceFilesAreCurrent(
                cache: cache,
                roots: expectedRoots,
                calendar: range.calendar)
        }
        guard !allowEstablishedEmpty || cache.lastScanUnixMs > 0 else { return nil }
        guard allowEstablishedEmpty || !cache.daysByProvider.isEmpty else { return nil }
        guard !self.requestedWindowExpandsCache(range: range, cache: cache) else { return nil }

        let pricingContext = self.pricingContext(now: now, cacheRoot: cacheRoot)
        guard cache.pricingKey == pricingContext.pricingKey else { return nil }
        guard let reports = self.checkedReports(cache: cache, range: range) else { return nil }
        guard provider != .pi || !self.hasUnsupportedHistory(cache: cache, range: range) else { return nil }
        // Provider-specific by design: the Pi cache's aggregate view merges its fixed Codex and Claude tariffs.
        let report = if provider == .pi {
            CostUsageDailyReport.merged([reports.codex, reports.claude], calendar: range.calendar)
        } else {
            provider == .codex ? reports.codex : reports.claude
        }
        guard allowEstablishedEmpty || !report.data.isEmpty else { return nil }
        let lastScanAt = cache.lastScanUnixMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)
            : nil
        return CachedDailyReportResult(
            report: report,
            lastScanAt: lastScanAt,
            scopeFingerprint: cache.sessionRootsFingerprint,
            isComplete: sourcesAreComplete)
    }

    private static func hasUnsupportedHistory(
        cache: PiSessionCostCache,
        range: CostUsageScanner.CostUsageDayRange) -> Bool
    {
        cache.files.values.contains { file in
            file.hasUndatedUnsupportedAssistant || file.unsupportedAssistantDayKeys.contains {
                CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
            }
        }
    }

    private static func pricingContext(now: Date, cacheRoot: URL?) -> ModelsDevPricingContext {
        let modelsDevArtifact = ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact
        let customPricingFingerprint = CostUsageCustomPricing.load().fingerprint
        return ModelsDevPricingContext(
            catalog: modelsDevArtifact?.catalog,
            cacheRoot: cacheRoot,
            pricingKey: CostUsagePricingKey.codex(
                modelsDevArtifact: modelsDevArtifact,
                formulaVersion: Self.costFormulaVersion,
                parserHash: CodexParserHash.value,
                modelsDevProviderIDs: CostUsagePricing.codexModelsDevProviderIDs.union(
                    Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs)),
                customPricingFingerprint: customPricingFingerprint))
    }

    private static func requestedWindowExpandsCache(
        range: CostUsageScanner.CostUsageDayRange,
        cache: PiSessionCostCache) -> Bool
    {
        guard let cachedSince = cache.scanSinceKey,
              let cachedUntil = cache.scanUntilKey
        else {
            return true
        }

        if range.scanSinceKey < cachedSince {
            return true
        }
        if range.scanUntilKey > cachedUntil {
            return true
        }
        return false
    }

    private static func defaultSessionRoots(
        options: Options,
        previousSessionRootsFingerprint: String?) -> [SessionRoot]
    {
        if options.piSessionsRoot != nil || options.ompSessionsRoot != nil {
            return [options.piSessionsRoot, options.ompSessionsRoot]
                .compactMap(\.self)
                .map {
                    SessionRoot(
                        url: $0,
                        missingIsKnownEmpty: false,
                        resolutionIsComplete: true,
                        preserveAfterProcessExit: false,
                        retentionKeys: [])
                }
        }

        let resolved = PiFamilySessionScanner.costSessionRoots(
            environment: options.environment,
            baseDirectories: options.workingDirectories.isEmpty
                ? options.workingDirectory.map { [$0] }
                : options.workingDirectories,
            processContexts: options.processContexts)
        if !resolved.isEmpty {
            let resolvedRoots = resolved.map { root in
                SessionRoot(
                    url: root.url,
                    missingIsKnownEmpty: root.missingIsKnownEmpty,
                    resolutionIsComplete: root.resolutionIsComplete,
                    preserveAfterProcessExit: root.preserveAfterProcessExit,
                    retentionKeys: root.retentionKeys)
            }
            return self.appendingPreviousSessionRoots(
                resolvedRoots,
                fingerprint: previousSessionRootsFingerprint)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        // Provider-specific by design: Pi-family stores use the fixed .pi and .omp home directories.
        let fallbackRoots = [".pi", ".omp"].map { directory in
            SessionRoot(
                url: home
                    .appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent("agent", isDirectory: true)
                    .appendingPathComponent("sessions", isDirectory: true),
                missingIsKnownEmpty: true,
                resolutionIsComplete: true,
                preserveAfterProcessExit: false,
                retentionKeys: [])
        }
        return self.appendingPreviousSessionRoots(
            fallbackRoots,
            fingerprint: previousSessionRootsFingerprint)
    }

    private static func appendingPreviousSessionRoots(
        _ roots: [SessionRoot],
        fingerprint: String?) -> [SessionRoot]
    {
        var output: [SessionRoot] = []
        var indices: [String: Int] = [:]
        func appendRoot(_ root: SessionRoot) {
            guard let index = indices[root.url.path] else {
                indices[root.url.path] = output.count
                output.append(root)
                return
            }
            let current = output[index]
            output[index] = SessionRoot(
                url: root.url,
                missingIsKnownEmpty: current.missingIsKnownEmpty && root.missingIsKnownEmpty,
                resolutionIsComplete: current.resolutionIsComplete && root.resolutionIsComplete,
                preserveAfterProcessExit: current.preserveAfterProcessExit || root.preserveAfterProcessExit,
                retentionKeys: current.retentionKeys.union(root.retentionKeys))
        }
        roots.forEach(appendRoot)
        guard let fingerprint, !fingerprint.isEmpty else { return output }
        let currentRetentionKeys = Set(roots.flatMap(\.retentionKeys))
        let currentSettingsRetentionKeys = Set(currentRetentionKeys.filter { $0.hasPrefix("settings:") })
        for component in fingerprint.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
            let fields = component.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count >= 4, fields[3] == "live" else { continue }
            let path = String(fields[0])
            guard !path.isEmpty, !path.hasPrefix("/.codexbar-unresolved-") else { continue }
            let retentionKey = fields.count >= 5 && !fields[4].isEmpty ? String(fields[4]) : nil
            // A settings file is a replacement point: if it now resolves to another root, the
            // prior root belonged to the superseded selector and must not be carried forward.
            if let retentionKey, currentRetentionKeys.contains(retentionKey) { continue }
            if let retentionKey, retentionKey.hasPrefix("settings:") {
                switch PiFamilySessionScanner.retainedSettingsRootResolution(retentionKey: retentionKey) {
                case .removed:
                    // The settings selector was removed, so its retained root is obsolete.
                    continue
                case let .resolved(url, resolvedRetentionKey):
                    let resolvedURL = url.standardizedFileURL
                    appendRoot(SessionRoot(
                        url: resolvedURL,
                        missingIsKnownEmpty: fields[1] == "known-empty",
                        resolutionIsComplete: true,
                        preserveAfterProcessExit: true,
                        retentionKeys: [resolvedRetentionKey]))
                    continue
                case .unavailable:
                    // Preserve the cached root while marking the scope incomplete. This avoids
                    // silently dropping history when the settings file cannot be revalidated.
                    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                    appendRoot(SessionRoot(
                        url: url,
                        missingIsKnownEmpty: fields[1] == "known-empty",
                        resolutionIsComplete: false,
                        preserveAfterProcessExit: true,
                        retentionKeys: [retentionKey]))
                    continue
                }
            }
            // Legacy fingerprints did not record provenance. If the current scope has a settings
            // selector, prefer its current value over an ambiguous retained settings root.
            if retentionKey == nil, !currentSettingsRetentionKeys.isEmpty { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            appendRoot(SessionRoot(
                url: url,
                missingIsKnownEmpty: fields[1] == "known-empty",
                resolutionIsComplete: fields[2] == "resolved",
                preserveAfterProcessExit: true,
                retentionKeys: retentionKey.map { [$0] } ?? []))
        }
        return output
    }

    private static func sessionRootsFingerprint(_ roots: [SessionRoot]) -> String {
        roots
            .flatMap { root in
                (root.retentionKeys.isEmpty ? [""] : root.retentionKeys.sorted()).map { retentionKey in
                    [
                        root.url.path,
                        root.missingIsKnownEmpty ? "known-empty" : "required",
                        root.resolutionIsComplete ? "resolved" : "unresolved",
                        root.preserveAfterProcessExit ? "live" : "configured",
                        retentionKey,
                    ].joined(separator: "\u{1F}")
                }
            }
            .joined(separator: "\u{1E}")
    }

    /// Returns the root scope represented by a Pi scanner configuration. Cached
    /// reads use this to reject a report produced for a different live or
    /// configured project root before publishing it.
    package static func scopeFingerprint(options: Options) -> String {
        let cache = PiSessionCostCacheIO.load(cacheRoot: options.cacheRoot)
        return self.scopeFingerprint(
            options: options,
            cache: cache)
    }

    private struct SessionFileListResult {
        let files: [URL]
        let isComplete: Bool
    }

    private struct SessionFileMetadata: Equatable {
        let fileIdentity: String
        let mtimeUnixMs: Int64
        let size: Int64

        func matches(_ cached: PiSessionFileUsage) -> Bool {
            cached.fileIdentity == self.fileIdentity &&
                cached.mtimeUnixMs == self.mtimeUnixMs &&
                cached.size == self.size &&
                cached.parsedBytes == cached.size
        }
    }

    private static func sessionFileMetadata(at url: URL) -> SessionFileMetadata? {
        let path = url.path
        guard FileManager.default.isReadableFile(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let modifiedAt = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size >= 0
        else { return nil }
        return SessionFileMetadata(
            fileIdentity: "\(device):\(inode)",
            mtimeUnixMs: Int64(modifiedAt.timeIntervalSince1970 * 1000),
            size: size)
    }

    private static func cachedSourceFilesAreCurrent(
        cache: PiSessionCostCache,
        roots: [SessionRoot],
        calendar: Calendar) -> Bool
    {
        guard !roots.isEmpty,
              roots.allSatisfy(\.resolutionIsComplete),
              cache.lastScanUnixMs > 0,
              let sinceKey = cache.scanSinceKey,
              let cutoff = self.dateFromDayKey(sinceKey, calendar: calendar)
        else { return false }

        // Compare the persisted scan window, even when the caller displays a narrower period.
        var paths = Set<String>()
        for root in roots {
            let inventory = self.listPiSessionFiles(
                root: root.url,
                startCutoffLocal: cutoff,
                calendar: calendar,
                missingIsKnownEmpty: root.missingIsKnownEmpty)
            guard inventory.isComplete else { return false }
            for candidate in inventory.files {
                let url = self.canonicalSessionFileURL(candidate)
                guard paths.insert(url.path).inserted else { continue }
                guard let cached = cache.files[url.path],
                      let metadata = self.sessionFileMetadata(at: url),
                      metadata.matches(cached)
                else { return false }
            }
        }
        return paths == Set(cache.files.keys)
    }

    private static func listPiSessionFiles(
        root: URL,
        startCutoffLocal: Date,
        calendar: Calendar,
        missingIsKnownEmpty: Bool) -> SessionFileListResult
    {
        guard FileManager.default.fileExists(atPath: root.path) else {
            // A missing default store is a known empty store, but a missing configured root may
            // indicate an unmounted or unavailable location and must keep the scan incomplete.
            return SessionFileListResult(files: [], isComplete: missingIsKnownEmpty)
        }

        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues?.isDirectory == true else {
            return SessionFileListResult(files: [], isComplete: false)
        }
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            return SessionFileListResult(files: [], isComplete: false)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        var isComplete = true
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                isComplete = false
                return true
            })
        else {
            return SessionFileListResult(files: [], isComplete: false)
        }

        var output: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: keys)
            } catch {
                isComplete = false
                continue
            }
            guard values.isRegularFile == true else { continue }

            let startedAt = self.parseSessionStartFromFilename(item.lastPathComponent)
            let modifiedAt = values.contentModificationDate
            if self
                .shouldIncludeFile(
                    startedAt: startedAt,
                    modifiedAt: modifiedAt,
                    startCutoffLocal: startCutoffLocal,
                    calendar: calendar)
            {
                output.append(item)
            }
        }

        return SessionFileListResult(
            files: output.sorted(by: { $0.path < $1.path }),
            isComplete: isComplete)
    }

    private static func shouldIncludeFile(
        startedAt: Date?,
        modifiedAt: Date?,
        startCutoffLocal: Date,
        calendar: Calendar) -> Bool
    {
        if let modifiedAt, self.localMidnight(modifiedAt, calendar: calendar) >= startCutoffLocal {
            return true
        }
        if let startedAt, self.localMidnight(startedAt, calendar: calendar) >= startCutoffLocal {
            return true
        }
        return false
    }

    private static func scanPiSessionFile(
        fileURL: URL,
        cache: inout PiSessionCostCache,
        context: ScanContext)
        throws -> Bool
    {
        try context.checkCancellation?()
        let path = fileURL.path
        guard let metadata = self.sessionFileMetadata(at: fileURL) else { return false }
        let fileIdentity = metadata.fileIdentity
        let mtimeMs = metadata.mtimeUnixMs
        let size = metadata.size

        func storeFileUsage(_ usage: PiSessionFileUsage) {
            cache.files[path] = usage
        }

        let cached = cache.files[path]
        if !context.forceRescan,
           let cached,
           metadata.matches(cached)
        {
            return true
        }

        if !context.forceRescan,
           let cached,
           cached.fileIdentity == fileIdentity,
           !cached.requiresFullReparseOnChange,
           size > cached.size,
           cached.parsedBytes > 0,
           cached.parsedBytes <= size
        {
            let delta = try self.parsePiSessionFile(
                fileURL: fileURL,
                range: context.range,
                startOffset: cached.parsedBytes,
                initialSessionID: cached.sessionID,
                initialModelContext: cached.lastModelContext,
                pricingContext: context.pricingContext,
                checkCancellation: context.checkCancellation)
            guard delta.isComplete, self.sessionFileMetadata(at: fileURL) == metadata else { return false }
            guard let merged = self.mergedContributions(existing: cached.contributions, delta: delta.contributions),
                  let mergedUnkeyed = self.mergedContributions(
                      existing: cached.unkeyedContributions,
                      delta: delta.unkeyedContributions)
            else { return false }
            let mergedEntryUsages = cached.entryUsages.merging(delta.entryUsages) { _, appended in appended }
            storeFileUsage(PiSessionFileUsage(
                mtimeUnixMs: mtimeMs,
                size: size,
                parsedBytes: delta.parsedBytes,
                fileIdentity: fileIdentity,
                sessionID: delta.sessionID ?? cached.sessionID,
                lastModelContext: delta.lastModelContext,
                contributions: merged,
                unkeyedContributions: mergedUnkeyed,
                entryUsages: mergedEntryUsages,
                unsupportedAssistantDayKeys: cached.unsupportedAssistantDayKeys
                    .union(delta.unsupportedAssistantDayKeys),
                hasUndatedUnsupportedAssistant: cached.hasUndatedUnsupportedAssistant ||
                    delta.hasUndatedUnsupportedAssistant))
            return true
        }

        let parsed = try self.parsePiSessionFile(
            fileURL: fileURL,
            range: context.range,
            pricingContext: context.pricingContext,
            checkCancellation: context.checkCancellation)
        guard parsed.isComplete, self.sessionFileMetadata(at: fileURL) == metadata else { return false }

        storeFileUsage(PiSessionFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            parsedBytes: parsed.parsedBytes,
            fileIdentity: fileIdentity,
            sessionID: parsed.sessionID,
            lastModelContext: parsed.lastModelContext,
            contributions: parsed.contributions,
            unkeyedContributions: parsed.unkeyedContributions,
            entryUsages: parsed.entryUsages,
            unsupportedAssistantDayKeys: parsed.unsupportedAssistantDayKeys,
            hasUndatedUnsupportedAssistant: parsed.hasUndatedUnsupportedAssistant))
        return true
    }

    private static func parsePiSessionFile(
        fileURL: URL,
        range: CostUsageScanner.CostUsageDayRange,
        startOffset: Int64 = 0,
        initialSessionID: String? = nil,
        initialModelContext: PiModelContext? = nil,
        pricingContext: ModelsDevPricingContext? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> ParseResult
    {
        self.sessionParseObserverForTesting?()
        var sessionID = initialSessionID
        var currentModelContext = initialModelContext
        var contributions: [String: [String: [String: PiPackedUsage]]] = [:]
        var unkeyedContributions: [String: [String: [String: PiPackedUsage]]] = [:]
        var entryUsages: [String: PiSessionEntryUsage] = [:]
        var unsupportedAssistantDayKeys: Set<String> = []
        var hasUndatedUnsupportedAssistant = false
        var isComplete = true

        func add(
            provider: UsageProvider,
            dayKey: String,
            modelName: String,
            usage: PiPackedUsage,
            entryID: String?)
        {
            guard !usage.isZero else { return }
            let providerKey = provider.rawValue
            let delta = [providerKey: [dayKey: [modelName: usage]]]
            guard self.applyContributions(daysByProvider: &contributions, contributions: delta) else {
                isComplete = false
                return
            }

            if let entryID {
                entryUsages[entryID] = PiSessionEntryUsage(
                    providerRawValue: providerKey,
                    dayKey: dayKey,
                    modelName: modelName,
                    usage: usage)
            } else {
                guard self.applyContributions(daysByProvider: &unkeyedContributions, contributions: delta)
                else {
                    isComplete = false
                    return
                }
            }
        }

        let parsedBytes: Int64
        do {
            parsedBytes = try CostUsageJsonl.scan(
                fileURL: fileURL,
                offset: startOffset,
                maxLineBytes: Self.maxLineBytes,
                prefixBytes: Self.maxLineBytes,
                checkCancellation: checkCancellation,
                onLine: { line in
                    guard !line.bytes.isEmpty else { return }
                    if line.wasTruncated {
                        // Dropping an oversized record must not advance the cache past usage we
                        // could not parse; retain the previous file snapshot and retry later.
                        isComplete = false
                        return
                    }
                    autoreleasepool {
                        guard let objectValue = try? JSONSerialization.jsonObject(with: line.bytes),
                              let object = objectValue as? [String: Any]
                        else {
                            // A terminated but malformed/non-object record means the file was not
                            // fully interpreted; keep the prior cache snapshot and retry later.
                            isComplete = false
                            return
                        }
                        guard let type = object["type"] as? String else { return }

                        if type == "session" {
                            sessionID = sessionID ?? self.sessionIdentifier(from: object)
                            return
                        }

                        if type == "model_change" {
                            currentModelContext = self.modelContext(from: object)
                            return
                        }

                        guard type == "message", let message = object["message"] as? [String: Any] else { return }
                        guard (message["role"] as? String) == "assistant" else { return }

                        let identity = self.resolveAssistantIdentity(
                            entry: object,
                            message: message,
                            fallback: currentModelContext)
                        guard let identity else {
                            let unsupported = if let explicit = self.extractProviderText(
                                entry: object,
                                message: message)
                            {
                                self.mappedProvider(fromPiProvider: explicit) == nil
                            } else {
                                currentModelContext?.isUnsupportedBackend == true
                            }
                            guard unsupported else {
                                isComplete = false
                                return
                            }
                            if let date = self.timestampDate(entry: object, message: message) {
                                let day = CostUsageScanner.CostUsageDayRange.dayKey(
                                    from: date,
                                    calendar: range.calendar)
                                if CostUsageScanner.CostUsageDayRange.isInRange(
                                    dayKey: day, since: range.scanSinceKey, until: range.scanUntilKey)
                                {
                                    unsupportedAssistantDayKeys.insert(day)
                                }
                            } else {
                                hasUndatedUnsupportedAssistant = true
                            }
                            return
                        }
                        guard let date = self.timestampDate(entry: object, message: message) else {
                            // A recognized assistant row without a usable timestamp cannot be
                            // assigned to a day. Keep the scan incomplete so cache advancement
                            // never permanently hides its usage.
                            isComplete = false
                            return
                        }
                        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(
                            from: date,
                            calendar: range.calendar)
                        guard CostUsageScanner.CostUsageDayRange.isInRange(
                            dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
                        else { return }
                        guard let usage = self.extractUsage(
                            provider: identity.provider,
                            modelName: identity.modelName,
                            message: message,
                            pricingDate: date,
                            pricingContext: pricingContext)
                        else {
                            isComplete = false
                            return
                        }
                        add(
                            provider: identity.provider,
                            dayKey: dayKey,
                            modelName: identity.modelName,
                            usage: usage,
                            entryID: self.entryIdentifier(from: object))
                    }
                })
            // A scan can stop at the last complete newline while an active writer leaves a
            // partial JSON object at EOF. The committed offset then trails the file size, so
            // keep the cache incomplete and retry the tail on a later refresh.
            let observedFileSize = (try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
                            .int64Value
            if observedFileSize != parsedBytes {
                isComplete = false
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            parsedBytes = startOffset
            isComplete = false
        }

        return ParseResult(
            contributions: contributions,
            unkeyedContributions: unkeyedContributions,
            entryUsages: entryUsages,
            parsedBytes: parsedBytes,
            sessionID: sessionID,
            lastModelContext: currentModelContext,
            isComplete: isComplete,
            unsupportedAssistantDayKeys: unsupportedAssistantDayKeys,
            hasUndatedUnsupportedAssistant: hasUndatedUnsupportedAssistant)
    }

    private static func sessionIdentifier(from object: [String: Any]) -> String? {
        let candidate = ["id", "sessionId", "session_id"]
            .compactMap { object[$0] as? String }
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !candidate.isEmpty, candidate.utf8.count <= 1024 else { return nil }
        return candidate
    }

    private static func entryIdentifier(from object: [String: Any]) -> String? {
        let candidate = (object["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !candidate.isEmpty, candidate.utf8.count <= 1024 else { return nil }
        return candidate
    }

    private static func rebuildDailyUsage(
        cache: inout PiSessionCostCache,
        files: [SessionFileCandidate],
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> Bool
    {
        var seenEntriesBySessionID: [String: Set<String>] = [:]
        var days: [String: [String: [String: PiPackedUsage]]] = [:]

        for file in files {
            try checkCancellation?()
            guard let usage = cache.files[file.url.path] else { continue }
            guard let sessionID = usage.sessionID else {
                guard self.applyContributions(daysByProvider: &days, contributions: usage.contributions) else {
                    return false
                }
                continue
            }

            guard self.applyContributions(daysByProvider: &days, contributions: usage.unkeyedContributions) else {
                return false
            }

            var seenEntries = seenEntriesBySessionID[sessionID] ?? []
            for entryID in usage.entryUsages.keys.sorted() where seenEntries.insert(entryID).inserted {
                guard let entryUsage = usage.entryUsages[entryID] else { continue }
                guard self.applyEntryUsage(daysByProvider: &days, entryUsage: entryUsage) else { return false }
            }
            seenEntriesBySessionID[sessionID] = seenEntries
        }
        cache.daysByProvider = days
        return true
    }

    private static func applyEntryUsage(
        daysByProvider: inout [String: [String: [String: PiPackedUsage]]],
        entryUsage: PiSessionEntryUsage) -> Bool
    {
        let contributions = [
            entryUsage.providerRawValue: [
                entryUsage.dayKey: [entryUsage.modelName: entryUsage.usage],
            ],
        ]
        return self.applyContributions(daysByProvider: &daysByProvider, contributions: contributions)
    }

    private static func modelContext(from object: [String: Any]) -> PiModelContext? {
        guard let providerText = object["provider"] as? String else { return nil }
        guard let provider = self.mappedProvider(fromPiProvider: providerText) else {
            return PiModelContext(providerRawValue: "", modelName: "", isUnsupportedBackend: true)
        }
        let rawModelName = (object["modelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let modelName = self.normalizeModelName(rawModelName, provider: provider) else { return nil }
        return PiModelContext(providerRawValue: provider.rawValue, modelName: modelName)
    }

    private static func resolveAssistantIdentity(
        entry: [String: Any],
        message: [String: Any],
        fallback: PiModelContext?) -> AssistantIdentity?
    {
        let explicitProviderText = self.extractProviderText(entry: entry, message: message)
        let explicitProvider = explicitProviderText.flatMap(self.mappedProvider(fromPiProvider:))
        let explicitModelText = self.extractModelText(entry: entry, message: message)

        if explicitProviderText != nil, explicitProvider == nil {
            return nil
        }

        if let explicitProvider,
           let explicitModelText,
           let explicitModel = self.normalizeModelName(explicitModelText, provider: explicitProvider)
        {
            return AssistantIdentity(provider: explicitProvider, modelName: explicitModel)
        }

        if let explicitProvider,
           let fallback,
           fallback.providerRawValue == explicitProvider.rawValue
        {
            return AssistantIdentity(provider: explicitProvider, modelName: fallback.modelName)
        }

        if explicitProviderText == nil,
           let explicitModelText,
           let fallbackProvider = fallback.flatMap({ UsageProvider(rawValue: $0.providerRawValue) }),
           let explicitModel = self.normalizeModelName(explicitModelText, provider: fallbackProvider)
        {
            return AssistantIdentity(provider: fallbackProvider, modelName: explicitModel)
        }

        if explicitProviderText == nil,
           let fallback,
           let provider = UsageProvider(rawValue: fallback.providerRawValue)
        {
            return AssistantIdentity(provider: provider, modelName: fallback.modelName)
        }

        return nil
    }

    private static func extractProviderText(entry: [String: Any], message: [String: Any]) -> String? {
        if let provider = (message["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty
        {
            return provider
        }
        if let provider = (entry["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty
        {
            return provider
        }
        return nil
    }

    private static func extractModelText(entry: [String: Any], message: [String: Any]) -> String? {
        for value in [message["model"], entry["model"], message["modelId"], entry["modelId"]] {
            if let model = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                return model
            }
        }
        return nil
    }

    private static func normalizeModelName(_ raw: String, provider: UsageProvider) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Provider-specific by design: Pi model IDs require the vendor-specific Codex/Claude pricing normalizers.
        return switch provider {
        case .codex:
            CostUsagePricing.normalizeCodexModel(trimmed)
        case .claude:
            CostUsagePricing.normalizeClaudeModel(trimmed)
        default:
            trimmed
        }
    }

    private static func timestampDate(entry: [String: Any], message: [String: Any]) -> Date? {
        self.parseTimestampValue(message["timestamp"])
            ?? self.parseTimestampValue(entry["timestamp"])
    }

    private static func parseTimestampValue(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            // JSON booleans bridge to NSNumber on Darwin; they are not timestamps.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            return Date(timeIntervalSince1970: raw)
        }

        if let string = value as? String {
            if let numeric = Double(string), numeric.isFinite {
                if numeric > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: numeric / 1000)
                }
                return Date(timeIntervalSince1970: numeric)
            }
            return self.parseISO(string)
        }

        return nil
    }

    private static func extractUsage(
        provider: UsageProvider,
        modelName: String,
        message: [String: Any],
        pricingDate: Date? = nil,
        pricingContext: ModelsDevPricingContext? = nil) -> PiPackedUsage?
    {
        guard let usage = message["usage"] as? [String: Any] else { return nil }
        var hasCounter = false
        func read(_ value: Any?) -> Int? {
            if value != nil { hasCounter = true }
            return Self.readNonNegativeInt(value)
        }
        let input = read(
            usage["input"]
                ?? usage["inputTokens"]
                ?? usage["input_tokens"]
                ?? usage["promptTokens"]
                ?? usage["prompt_tokens"])
        let cacheRead = read(
            usage["cacheRead"]
                ?? usage["cacheReadTokens"]
                ?? usage["cache_read"]
                ?? usage["cache_read_tokens"]
                ?? usage["cacheReadInputTokens"]
                ?? usage["cache_read_input_tokens"])
        let cacheWrite = read(
            usage["cacheWrite"]
                ?? usage["cacheWriteTokens"]
                ?? usage["cache_write"]
                ?? usage["cache_write_tokens"]
                ?? usage["cacheCreationTokens"]
                ?? usage["cache_creation_tokens"]
                ?? usage["cacheCreationInputTokens"]
                ?? usage["cache_creation_input_tokens"])
        let output = read(
            usage["output"]
                ?? usage["outputTokens"]
                ?? usage["output_tokens"]
                ?? usage["completionTokens"]
                ?? usage["completion_tokens"])

        let directTotal = read(
            usage["totalTokens"]
                ?? usage["total_tokens"]
                ?? usage["tokenCount"]
                ?? usage["token_count"]
                ?? usage["tokens"])
        guard hasCounter, let input, let cacheRead, let cacheWrite, let output, let directTotal,
              let derivedTotal = CheckedSum.integers([input, cacheRead, cacheWrite, output])
        else { return nil }
        let totalTokens = max(directTotal, derivedTotal)

        let rawUsage = PiPackedUsage(
            inputTokens: input,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            outputTokens: output,
            totalTokens: totalTokens)
        // Pi-compatible JSONL does not record Anthropic cache retention, so use Pi's persisted default tariff.
        let costUSD = totalTokens == derivedTotal ? self.computedCostUSD(
            provider: provider,
            modelName: modelName,
            usage: rawUsage,
            pricingDate: pricingDate,
            pricingContext: pricingContext) : nil
        let costNanos = costUSD.flatMap { value -> Int64? in
            guard value.isFinite, value >= 0 else { return nil }
            return Int64(exactly: (value * self.costScale).rounded())
        }

        return PiPackedUsage(
            inputTokens: rawUsage.inputTokens,
            cacheReadTokens: rawUsage.cacheReadTokens,
            cacheWriteTokens: rawUsage.cacheWriteTokens,
            outputTokens: rawUsage.outputTokens,
            totalTokens: rawUsage.totalTokens,
            costNanos: costNanos ?? 0,
            costSampleCount: costNanos == nil ? 0 : 1,
            usageSampleCount: 1)
    }

    private static func computedCostUSD(
        provider: UsageProvider,
        modelName: String,
        usage: PiPackedUsage,
        pricingDate: Date? = nil,
        pricingContext: ModelsDevPricingContext? = nil) -> Double?
    {
        // Provider-specific by design: Pi pricing delegates to the Codex and Claude tariff calculators.
        switch provider {
        case .codex:
            // Pi records input, cache reads, and cache writes as disjoint counts. Codex pricing
            // expects cached/write tokens to be subsets of total input, so reconstruct that total
            // here and pass writes separately (1.25x input for GPT-5.6 when rates are known).
            CostUsagePricing.codexCostUSD(
                model: modelName,
                inputTokens: usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens,
                cachedInputTokens: usage.cacheReadTokens,
                outputTokens: usage.outputTokens,
                cacheWriteInputTokens: usage.cacheWriteTokens,
                pricingDate: pricingDate,
                modelsDevCatalog: pricingContext?.catalog,
                modelsDevCacheRoot: pricingContext?.cacheRoot)
        // Provider-specific by design: Claude uses its own first-party input/cache/output tariff.
        case .claude:
            CostUsagePricing.claudeCostUSD(
                model: modelName,
                inputTokens: usage.inputTokens,
                cacheReadInputTokens: usage.cacheReadTokens,
                cacheCreationInputTokens: usage.cacheWriteTokens,
                outputTokens: usage.outputTokens,
                pricingDate: pricingDate,
                modelsDevCatalog: pricingContext?.catalog,
                modelsDevCacheRoot: pricingContext?.cacheRoot)
        default:
            nil
        }
    }

    private static func readNonNegativeInt(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        let text: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            text = number.stringValue
        } else if let string = value as? String {
            text = string
        } else {
            return nil
        }
        if let integer = Int(text) { return integer >= 0 ? integer : nil }
        guard let numeric = Double(text), numeric.isFinite, numeric >= 0 else { return nil }
        return Int(exactly: numeric.rounded())
    }
}

extension PiSessionCostScanner {
    private static func mappedProvider(fromPiProvider provider: String) -> UsageProvider? {
        // Provider-specific by design: Pi currently records the Codex and Anthropic integrations it can price.
        switch provider.lowercased() {
        case "openai-codex":
            .codex
        case "anthropic":
            .claude
        default:
            nil
        }
    }

    private static func parseSessionStartFromFilename(_ filename: String) -> Date? {
        guard let regex = self.sessionStartFilenameRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range) else { return nil }
        guard (1...5).allSatisfy({ Range(match.range(at: $0), in: filename) != nil }) else { return nil }
        let date = String(filename[Range(match.range(at: 1), in: filename)!])
        let hour = String(filename[Range(match.range(at: 2), in: filename)!])
        let minute = String(filename[Range(match.range(at: 3), in: filename)!])
        let second = String(filename[Range(match.range(at: 4), in: filename)!])
        let millis = String(filename[Range(match.range(at: 5), in: filename)!])
        return self.parseISO("\(date)T\(hour):\(minute):\(second).\(millis)Z")
    }

    private static func parseISO(_ text: String) -> Date? {
        self.isoFormatterBox.lock.lock()
        defer { self.isoFormatterBox.lock.unlock() }
        return self.isoFormatterBox.withFractional.date(from: text)
            ?? self.isoFormatterBox.plain.date(from: text)
    }

    private static func localMidnight(_ date: Date, calendar: Calendar) -> Date {
        let calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: components) ?? date
    }

    private static func canonicalSessionFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func dateFromDayKey(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }

        let calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        return components.date
    }

    private static func scopeFingerprint(options: Options, cache originalCache: PiSessionCostCache) -> String {
        let cache = originalCache
        let roots = self.defaultSessionRoots(
            options: options,
            previousSessionRootsFingerprint: cache.sessionRootsFingerprint)
        // An incomplete root resolution restores the cached report wholesale. Advertise that
        // retained scope so callers do not reject the report as belonging to a different dataset.
        if roots.contains(where: { !$0.resolutionIsComplete }),
           let cachedScope = cache.sessionRootsFingerprint,
           !cachedScope.isEmpty
        {
            return cachedScope
        }
        return self.sessionRootsFingerprint(roots)
    }
}
