#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// swiftlint:disable type_body_length
enum CostUsageScanner {
    static let log = CodexBarLog.logger(LogCategories.tokenCost)
    static let codexActiveSessionLookbackDays = 30
    static let costScale = 1_000_000_000.0

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options {
        var codexSessionsRoot: URL?
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        var codexTraceDatabaseURL: URL?
        var refreshMinIntervalSeconds: TimeInterval = 60
        var claudeLogProviderFilter: ClaudeLogProviderFilter = .all
        /// Force a full rescan, ignoring per-file cache and incremental offsets.
        var forceRescan: Bool = false

        init(
            codexSessionsRoot: URL? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            codexTraceDatabaseURL: URL? = nil,
            claudeLogProviderFilter: ClaudeLogProviderFilter = .all,
            forceRescan: Bool = false)
        {
            self.codexSessionsRoot = codexSessionsRoot
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.codexTraceDatabaseURL = codexTraceDatabaseURL
            self.claudeLogProviderFilter = claudeLogProviderFilter
            self.forceRescan = forceRescan
        }
    }

    struct CodexParseResult {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
        let lastModel: String?
        let lastTotals: CostUsageCodexTotals?
        let lastCountedTotals: CostUsageCodexTotals?
        let lastRawTotalsBaseline: CostUsageCodexTotals?
        let hasDivergentTotals: Bool
        let lastCodexTurnID: String?
        let sessionId: String?
        let forkedFromId: String?
        let rows: [CodexUsageRow]
    }

    struct CodexUsageRow: Codable, Equatable {
        let day: String
        let model: String
        let turnID: String?
        let input: Int
        let cached: Int
        let output: Int
    }

    struct CodexScanState {
        var seenSessionIds: Set<String> = []
        var seenFileIds: Set<String> = []
    }

    private struct CodexTimestampedTotals {
        let timestamp: String
        let date: Date?
        let totals: CostUsageCodexTotals
    }

    private static func codexTotalsEqual(_ lhs: CostUsageCodexTotals?, _ rhs: CostUsageCodexTotals?) -> Bool {
        lhs?.input == rhs?.input && lhs?.cached == rhs?.cached && lhs?.output == rhs?.output
    }

    private static func codexAddTotals(
        _ lhs: CostUsageCodexTotals,
        _ rhs: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        CostUsageCodexTotals(
            input: lhs.input + rhs.input,
            cached: lhs.cached + rhs.cached,
            output: lhs.output + rhs.output)
    }

    private static func codexTotalDelta(
        from baseline: CostUsageCodexTotals?,
        to current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let baseline = baseline ?? .init(input: 0, cached: 0, output: 0)
        return CostUsageCodexTotals(
            input: max(0, current.input - baseline.input),
            cached: max(0, current.cached - baseline.cached),
            output: max(0, current.output - baseline.output))
    }

    private static func codexDivergentTotalDelta(
        rawBaseline: CostUsageCodexTotals?,
        countedBaseline: CostUsageCodexTotals?,
        current: CostUsageCodexTotals) -> CostUsageCodexTotals
    {
        let rawBaseline = rawBaseline ?? .init(input: 0, cached: 0, output: 0)
        let countedBaseline = countedBaseline ?? .init(input: 0, cached: 0, output: 0)

        func delta(raw: Int, counted: Int, current: Int) -> Int {
            if current >= raw {
                return max(0, current - raw)
            }
            return max(0, current - counted)
        }

        return CostUsageCodexTotals(
            input: delta(raw: rawBaseline.input, counted: countedBaseline.input, current: current.input),
            cached: delta(raw: rawBaseline.cached, counted: countedBaseline.cached, current: current.cached),
            output: delta(raw: rawBaseline.output, counted: countedBaseline.output, current: current.output))
    }

    struct CodexScanResources {
        let fileIndex: CodexSessionFileIndex
        let inheritedResolver: CodexInheritedTotalsResolver
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let priorityTurns: [String: CodexPriorityTurnMetadata]
    }

    struct CodexFileScanContext {
        let range: CostUsageDayRange
        let forceFullScan: Bool
        let dropDeferredCodexRows: Bool
        let requiresTurnIDCache: Bool
        let changedPriorityTurnIDs: Set<String>
        let resources: CodexScanResources
    }

    struct CodexRefreshPlan {
        let refreshMs: Int64
        let roots: [URL]
        let rootsFingerprint: [String: Int64]
        let rootsChanged: Bool
        let windowExpanded: Bool
        let needsCostCacheMigration: Bool
        let modelsDevCatalog: ModelsDevCatalog?
        let codexPricingKey: String
        let codexPriorityMetadataKey: String
        let hasPriorityMetadata: Bool
        let priorityTurns: [String: CodexPriorityTurnMetadata]
        let priorityTurnKeys: [String: String]
        let priorityTurnIDsByDay: [String: [String]]
        let pricingChanged: Bool
        let priorityMetadataChanged: Bool
        let priorityTurnsChanged: Bool
        let needsTurnIDCacheMigration: Bool
        let changedPriorityTurnIDs: Set<String>
        let shouldRefresh: Bool
    }

    final class CodexSessionFileIndex {
        private let files: [URL]
        private let filePaths: Set<String>
        private let roots: [URL]
        private var nextUnindexedFile = 0
        private var didIndexRoots = false
        private var fileURLBySessionId: [String: URL] = [:]
        private var missingSessionIds: Set<String> = []

        init(files: [URL], roots: [URL], cachedSessionFiles: [String: URL] = [:]) {
            self.files = files
            self.filePaths = Set(files.map(\.path))
            self.roots = roots
            self.fileURLBySessionId = cachedSessionFiles
        }

        func remember(fileURL: URL, sessionId: String?) {
            guard let sessionId, !sessionId.isEmpty else { return }
            self.fileURLBySessionId[sessionId] = fileURL
        }

        func fileURL(for sessionId: String) -> URL? {
            if let cached = self.fileURLBySessionId[sessionId] {
                return cached
            }
            if self.missingSessionIds.contains(sessionId) {
                return nil
            }

            while self.nextUnindexedFile < self.files.count {
                let fileURL = self.files[self.nextUnindexedFile]
                self.nextUnindexedFile += 1
                guard let indexedSessionId = CostUsageScanner.parseCodexSessionIdentifier(fileURL: fileURL) else {
                    continue
                }
                self.fileURLBySessionId[indexedSessionId] = fileURL
                if indexedSessionId == sessionId {
                    return fileURL
                }
            }

            if !self.didIndexRoots {
                self.indexRoots()
                if let indexed = self.fileURLBySessionId[sessionId] {
                    return indexed
                }
            }

            self.missingSessionIds.insert(sessionId)
            return nil
        }

        private func indexRoots() {
            self.didIndexRoots = true
            guard !self.roots.isEmpty else { return }
            for root in self.roots {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                    guard !self.filePaths.contains(fileURL.path) else { continue }
                    guard let indexedSessionId = CostUsageScanner.parseCodexSessionIdentifier(fileURL: fileURL) else {
                        continue
                    }
                    self.fileURLBySessionId[indexedSessionId] = fileURL
                }
            }
        }
    }

    final class CodexInheritedTotalsResolver {
        private let fileIndex: CodexSessionFileIndex
        private var snapshotsBySessionId: [String: [CodexTimestampedTotals]] = [:]

        init(fileIndex: CodexSessionFileIndex) {
            self.fileIndex = fileIndex
        }

        func inheritedTotals(for sessionId: String, atOrBefore cutoffTimestamp: String) -> CostUsageCodexTotals? {
            guard !cutoffTimestamp.isEmpty else { return nil }
            let cutoffDate = CostUsageScanner.dateFromTimestamp(cutoffTimestamp)
            if cutoffDate == nil {
                CostUsageScanner.log.warning(
                    "Codex cost usage could not parse fork timestamp; falling back to lexical comparison",
                    metadata: ["sessionId": sessionId, "timestamp": cutoffTimestamp])
            }
            let snapshots = self.snapshots(for: sessionId)
            var inherited: CostUsageCodexTotals?
            for snapshot in snapshots {
                let isAtOrBefore: Bool = if let snapshotDate = snapshot.date, let cutoffDate {
                    snapshotDate <= cutoffDate
                } else {
                    snapshot.timestamp <= cutoffTimestamp
                }
                if isAtOrBefore {
                    inherited = snapshot.totals
                }
            }
            return inherited
        }

        private func snapshots(for sessionId: String) -> [CodexTimestampedTotals] {
            if let cached = self.snapshotsBySessionId[sessionId] {
                return cached
            }
            guard let fileURL = self.fileIndex.fileURL(for: sessionId) else {
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session file not found",
                    metadata: ["sessionId": sessionId])
                return []
            }
            let parsed = CostUsageScanner.parseCodexTokenSnapshots(fileURL: fileURL)
            guard let parsedSessionId = parsed.sessionId else {
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session missing session metadata",
                    metadata: ["sessionId": sessionId, "path": fileURL.path])
                return []
            }
            if parsedSessionId != sessionId {
                CostUsageScanner.log.warning(
                    "Codex cost usage parent session resolved to mismatched session id",
                    metadata: [
                        "requestedSessionId": sessionId,
                        "resolvedSessionId": parsedSessionId,
                        "path": fileURL.path,
                    ])
            }
            self.snapshotsBySessionId[parsedSessionId] = parsed.snapshots
            return self.snapshotsBySessionId[sessionId] ?? []
        }
    }

    struct ClaudeParseResult {
        let days: [String: [String: [Int]]]
        let rows: [ClaudeUsageRow]
        let parsedBytes: Int64
    }

    enum ClaudePathRole: String, Codable {
        case parent
        case subagent
    }

    struct ClaudeUsageRow: Codable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let messageId: String?
        let requestId: String?
        let isSidechain: Bool
        let pathRole: ClaudePathRole
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let output: Int
        let costNanos: Int
        let costPriced: Bool?
    }

    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        let range = CostUsageDayRange(since: since, until: until)
        let emptyReport = CostUsageDailyReport(data: [], summary: nil)

        switch provider {
        case .codex:
            return self.loadCodexDaily(range: range, now: now, options: options)
        case .claude:
            return self.loadClaudeDaily(provider: .claude, range: range, now: now, options: options)
        case .vertexai:
            var filtered = options
            if filtered.claudeLogProviderFilter == .all {
                filtered.claudeLogProviderFilter = .vertexAIOnly
            }
            return self.loadClaudeDaily(provider: .vertexai, range: range, now: now, options: filtered)
        case .openai, .zai, .gemini, .antigravity, .cursor, .opencode, .opencodego, .alibaba, .factory, .copilot,
             .minimax, .manus, .kilo, .kiro, .kimi, .kimik2, .moonshot, .augment, .jetbrains, .amp, .ollama,
             .synthetic, .openrouter, .elevenlabs, .warp, .perplexity, .mimo, .doubao, .abacus, .mistral,
             .deepseek, .codebuff, .crof, .windsurf, .venice, .commandcode, .stepfun, .bedrock, .grok, .groq,
             .llmproxy, .deepgram, .wafer:
            return emptyReport
        }
    }

    // MARK: - Day keys

    struct CostUsageDayRange {
        let sinceKey: String
        let untilKey: String
        let scanSinceKey: String
        let scanUntilKey: String

        init(since: Date, until: Date) {
            self.sinceKey = Self.dayKey(from: since)
            self.untilKey = Self.dayKey(from: until)
            self.scanSinceKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: -1, to: since) ?? since)
            self.scanUntilKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until)
        }

        static func dayKey(from date: Date) -> String {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            let y = comps.year ?? 1970
            let m = comps.month ?? 1
            let d = comps.day ?? 1
            return String(format: "%04d-%02d-%02d", y, m, d)
        }

        static func isInRange(dayKey: String, since: String, until: String) -> Bool {
            if dayKey < since { return false }
            if dayKey > until { return false }
            return true
        }
    }

    // MARK: - Codex

    private static func defaultCodexSessionsRoot(options: Options) -> URL {
        if let override = options.codexSessionsRoot { return override }
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func codexSessionsRoots(options: Options) -> [URL] {
        let root = self.defaultCodexSessionsRoot(options: options)
        if let archived = self.codexArchivedSessionsRoot(sessionsRoot: root) {
            return [root, archived]
        }
        return [root]
    }

    private static func codexArchivedSessionsRoot(sessionsRoot: URL) -> URL? {
        guard sessionsRoot.lastPathComponent == "sessions" else { return nil }
        return sessionsRoot
            .deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
    }

    private static func listCodexSessionFiles(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        includeRecursive: Bool) -> [URL]
    {
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: scanSinceKey,
            scanUntilKey: scanUntilKey)
        let flat = self.listCodexSessionFilesFlat(root: root, scanSinceKey: scanSinceKey, scanUntilKey: scanUntilKey)
        let recursive = includeRecursive ? self.listCodexLegacySessionFilesRecursive(root: root) : []
        var seen: Set<String> = []
        var out: [URL] = []
        for item in partitioned + flat + recursive where !seen.contains(item.path) {
            seen.insert(item.path)
            out.append(item)
        }
        return out
    }

    private static func cachedCodexSessionFiles(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        roots: [URL]) -> [URL]
    {
        cache.files.compactMap { path, usage in
            let hasRelevantDay = usage.days.keys.contains {
                CostUsageDayRange.isInRange(dayKey: $0, since: range.scanSinceKey, until: range.scanUntilKey)
            }
            guard hasRelevantDay else { return nil }
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let fileURL = URL(fileURLWithPath: path)
            guard Self.isWithinCodexRoots(fileURL: fileURL, roots: roots) else { return nil }
            return fileURL
        }
    }

    private static func cachedCodexSessionIndex(cache: CostUsageCache, roots: [URL]) -> [String: URL] {
        var out: [String: URL] = [:]
        for (path, usage) in cache.files {
            guard let sessionId = usage.sessionId, !sessionId.isEmpty else { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fileURL = URL(fileURLWithPath: path)
            guard Self.isWithinCodexRoots(fileURL: fileURL, roots: roots) else { continue }
            out[sessionId] = fileURL
        }
        return out
    }

    private static func codexRootsFingerprint(_ roots: [URL]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for root in roots {
            out[root.standardizedFileURL.path] = 0
        }
        return out
    }

    private static func codexPricingKey(modelsDevArtifact: ModelsDevCacheArtifact?) -> String {
        guard let modelsDevArtifact else {
            let fingerprint = CostUsagePricing.codexBuiltInPricingFingerprint()
            return "builtin-\(Self.sha256Hex(Data(fingerprint.utf8)))"
        }
        let fingerprint = self.modelsDevPricingFingerprint(modelsDevArtifact.catalog)
        return "models-dev-v\(modelsDevArtifact.version)-\(Self.sha256Hex(Data(fingerprint.utf8)))"
    }

    private static func modelsDevPricingFingerprint(_ catalog: ModelsDevCatalog) -> String {
        var parts: [String] = []
        for providerID in catalog.providers.keys.sorted() {
            guard let provider = catalog.providers[providerID] else { continue }
            parts.append("provider=\(providerID)|\(provider.id ?? "")")
            for modelKey in provider.models.keys.sorted() {
                guard let model = provider.models[modelKey] else { continue }
                let cost = model.cost
                let contextOver200K = cost?.contextOver200K
                parts.append([
                    "model=\(modelKey)",
                    model.id,
                    Self.optionalDoubleFingerprint(cost?.input),
                    Self.optionalDoubleFingerprint(cost?.output),
                    Self.optionalDoubleFingerprint(cost?.cacheRead),
                    Self.optionalDoubleFingerprint(cost?.cacheWrite),
                    Self.optionalDoubleFingerprint(contextOver200K?.input),
                    Self.optionalDoubleFingerprint(contextOver200K?.output),
                    Self.optionalDoubleFingerprint(contextOver200K?.cacheRead),
                    Self.optionalDoubleFingerprint(contextOver200K?.cacheWrite),
                    model.limit?.context.map(String.init) ?? "nil",
                ].joined(separator: "|"))
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func optionalDoubleFingerprint(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.17g", value)
    }

    private static func codexPriorityMetadataKey(databaseURL: URL?) -> String {
        let url = databaseURL ?? self.defaultCodexPriorityDatabaseURL()
        let path = url.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: path) ? "sqlite:\(path)" : "missing:\(path)"
    }

    private static func codexPriorityMetadataChanged(old: String?, new: String) -> Bool {
        guard let old, old != new else { return false }
        return new.hasPrefix("sqlite:")
    }

    private static func codexPriorityTurnKeys(
        _ priorityTurns: [String: CodexPriorityTurnMetadata]) -> [String: String]
    {
        var partsByDay: [String: [String]] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn) else { continue }
            partsByDay[dayKey, default: []].append([
                turnID,
                turn.model ?? "",
                turn.timestamp ?? "",
                turn.threadID ?? "",
            ].joined(separator: "|"))
        }
        var out: [String: String] = [:]
        for (dayKey, parts) in partsByDay {
            out[dayKey] = self.sha256Hex(Data(parts.sorted().joined(separator: "\n").utf8))
        }
        return out
    }

    private static func codexPriorityTurnIDsByDay(
        _ priorityTurns: [String: CodexPriorityTurnMetadata]) -> [String: [String]]
    {
        var out: [String: Set<String>] = [:]
        for (turnID, turn) in priorityTurns {
            guard let dayKey = self.codexPriorityDayKey(turn) else { continue }
            out[dayKey, default: []].insert(turnID)
        }
        return out.mapValues { $0.sorted() }
    }

    private static func codexPriorityDayKey(_ turn: CodexPriorityTurnMetadata) -> String? {
        guard let timestamp = turn.timestamp else { return nil }
        let dayKeyFromEpoch = Int64(timestamp).map {
            CostUsageDayRange.dayKey(from: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        return dayKeyFromEpoch ?? self.dayKeyFromTimestamp(timestamp) ?? self.dayKeyFromParsedISO(timestamp)
    }

    private static func codexPriorityTurnKeysChanged(
        old: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange) -> Bool
    {
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            where old?[dayKey] != new[dayKey]
        {
            return true
        }
        return false
    }

    private static func changedPriorityTurnIDs(
        old: [String: [String]]?,
        new: [String: [String]],
        range: CostUsageDayRange) -> Set<String>
    {
        var out = Set<String>()
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            let oldIDs = Set(old?[dayKey] ?? [])
            let newIDs = Set(new[dayKey] ?? [])
            if oldIDs != newIDs {
                out.formUnion(oldIDs)
                out.formUnion(newIDs)
            }
        }
        return out
    }

    private static func mergePriorityTurnKeys(
        existing: [String: String]?,
        new: [String: String],
        range: CostUsageDayRange,
        retainedSinceKey: String,
        retainedUntilKey: String) -> [String: String]?
    {
        var out = existing ?? [:]
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            out[dayKey] = new[dayKey]
        }
        out = out.filter { key, _ in
            CostUsageDayRange.isInRange(dayKey: key, since: retainedSinceKey, until: retainedUntilKey)
        }
        return out.isEmpty ? nil : out
    }

    private static func mergePriorityTurnIDsByDay(
        existing: [String: [String]]?,
        new: [String: [String]],
        range: CostUsageDayRange,
        retainedSinceKey: String,
        retainedUntilKey: String) -> [String: [String]]?
    {
        var out = existing ?? [:]
        for dayKey in self.dayKeys(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) {
            out[dayKey] = new[dayKey] ?? []
        }
        out = out.filter { key, _ in
            CostUsageDayRange.isInRange(dayKey: key, since: retainedSinceKey, until: retainedUntilKey)
        }
        return out.isEmpty ? nil : out
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func listCodexRecentlyModifiedFiles(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String,
        modifiedSince: Date) -> [URL]
    {
        let lookbackSinceKey = self.dayKey(scanSinceKey, addingDays: -self.codexActiveSessionLookbackDays)
            ?? scanSinceKey
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: lookbackSinceKey,
            scanUntilKey: scanUntilKey)
        let partitionedModified = self.filterRecentlyModified(files: partitioned, modifiedSince: modifiedSince)

        let legacyRecursive = self.listCodexRecentlyModifiedFilesRecursive(root: root, modifiedSince: modifiedSince)
        var seen = Set(partitionedModified.map(\.path))
        var out = partitionedModified
        for fileURL in legacyRecursive where !seen.contains(fileURL.path) {
            seen.insert(fileURL.path)
            out.append(fileURL)
        }
        return out
    }

    private static func filterRecentlyModified(files: [URL], modifiedSince: Date) -> [URL] {
        files.filter { fileURL in
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { return false }
            guard let modifiedAt = values?.contentModificationDate else { return false }
            return modifiedAt >= modifiedSince
        }
    }

    private static func isDatePartitionComponent(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy(\.isNumber)
    }

    private static func dayKey(_ dayKey: String, addingDays days: Int) -> String? {
        guard let date = self.parseDayKey(dayKey) else { return nil }
        guard let shifted = Calendar.current.date(byAdding: .day, value: days, to: date) else { return nil }
        return CostUsageDayRange.dayKey(from: shifted)
    }

    private static func dayKeys(sinceKey: String, untilKey: String) -> [String] {
        guard let since = self.parseDayKey(sinceKey),
              self.parseDayKey(untilKey) != nil
        else { return sinceKey <= untilKey ? [sinceKey] : [] }

        var out: [String] = []
        var cursor = since
        let calendar = Calendar.current
        while CostUsageDayRange.dayKey(from: cursor) <= untilKey {
            out.append(CostUsageDayRange.dayKey(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            if next <= cursor { break }
            cursor = next
        }
        return out
    }

    private static func listCodexRecentlyModifiedFilesRecursive(root: URL, modifiedSince: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard let modifiedAt = values?.contentModificationDate, modifiedAt >= modifiedSince else { continue }
            out.append(fileURL)
        }
        return out
    }

    private static func isWithinCodexRoots(fileURL: URL, roots: [URL]) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            if filePath == rootPath { return true }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return filePath.hasPrefix(prefix)
        }
    }

    private static func listCodexSessionFilesByDatePartition(
        root: URL,
        scanSinceKey: String,
        scanUntilKey: String) -> [URL]
    {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var out: [URL] = []
        var date = Self.parseDayKey(scanSinceKey) ?? Date()
        let untilDate = Self.parseDayKey(scanUntilKey) ?? date

        while date <= untilDate {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let y = String(format: "%04d", comps.year ?? 1970)
            let m = String(format: "%02d", comps.month ?? 1)
            let d = String(format: "%02d", comps.day ?? 1)

            let dayDir = root.appendingPathComponent(y, isDirectory: true)
                .appendingPathComponent(m, isDirectory: true)
                .appendingPathComponent(d, isDirectory: true)

            if let items = try? FileManager.default.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            {
                for item in items where item.pathExtension.lowercased() == "jsonl" {
                    out.append(item)
                }
            }

            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? untilDate.addingTimeInterval(1)
        }

        return out
    }

    private static func listCodexSessionFilesFlat(root: URL, scanSinceKey: String, scanUntilKey: String) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        for item in items where item.pathExtension.lowercased() == "jsonl" {
            if let dayKey = Self.dayKeyFromFilename(item.lastPathComponent) {
                if !CostUsageDayRange.isInRange(dayKey: dayKey, since: scanSinceKey, until: scanUntilKey) {
                    continue
                }
            }
            out.append(item)
        }
        return out
    }

    private static func listCodexLegacySessionFilesRecursive(root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if Self.isCodexDatePartitionAncestor(item, rootPath: rootPath) {
                enumerator.skipDescendants()
                continue
            }
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            out.append(item)
        }
        return out
    }

    private static func isCodexDatePartitionAncestor(_ url: URL, rootPath: String) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count + 1))
        let parts = relative.split(separator: "/")
        guard parts.count == 1 else { return false }
        return Self.isDatePartitionComponent(String(parts[0]), length: 4)
    }

    private static let codexFilenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    private static func dayKeyFromFilename(_ filename: String) -> String? {
        guard let regex = self.codexFilenameDateRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range) else { return nil }
        guard let matchRange = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[matchRange])
    }

    static func fileIdentityString(fileURL: URL) -> String? {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]) else { return nil }
        guard let identifier = values.fileResourceIdentifier else { return nil }
        if let data = identifier as? Data {
            return data.base64EncodedString()
        }
        return String(describing: identifier)
    }

    private struct CodexSessionMetadata {
        let sessionId: String?
        let forkedFromId: String?
        let forkTimestamp: String?
    }

    private static func parseCodexSessionIdentifier(fileURL: URL) -> String? {
        self.parseCodexSessionMetadata(fileURL: fileURL)?.sessionId
    }

    private static func parseCodexSessionMetadata(fileURL: URL) -> CodexSessionMetadata? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            self.log.warning(
                "Codex cost usage failed to open session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return nil
        }
        defer { try? handle.close() }

        var buffer = Data()
        let newline = Data([0x0A])

        func parseSessionMetadata(from lineData: Data) -> CodexSessionMetadata? {
            guard !lineData.isEmpty else { return nil }
            return autoreleasepool {
                guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                else { return nil }
                guard obj["type"] as? String == "session_meta" else { return nil }
                let payload = obj["payload"] as? [String: Any]
                return CodexSessionMetadata(
                    sessionId: payload?["session_id"] as? String
                        ?? payload?["sessionId"] as? String
                        ?? payload?["id"] as? String
                        ?? obj["session_id"] as? String
                        ?? obj["sessionId"] as? String
                        ?? obj["id"] as? String,
                    forkedFromId: payload?["forked_from_id"] as? String
                        ?? payload?["forkedFromId"] as? String
                        ?? payload?["parent_session_id"] as? String
                        ?? payload?["parentSessionId"] as? String,
                    forkTimestamp: payload?["timestamp"] as? String
                        ?? obj["timestamp"] as? String)
            }
        }

        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while let newlineRange = buffer.range(of: newline) {
                    let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                    buffer.removeSubrange(0..<newlineRange.upperBound)
                    if let metadata = parseSessionMetadata(from: lineData) {
                        return metadata
                    }
                }
            }
        } catch {
            self.log.warning(
                "Codex cost usage failed while reading session file for session id parsing",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            return nil
        }

        if let metadata = parseSessionMetadata(from: buffer) {
            return metadata
        }
        return nil
    }

    private static func parseCodexTokenSnapshots(fileURL: URL) -> (
        sessionId: String?,
        snapshots: [CodexTimestampedTotals])
    {
        var sessionId: String?
        var previousTotals: CostUsageCodexTotals?
        var rawTotalsBaseline: CostUsageCodexTotals?
        var sawDivergentTotals = false
        var snapshots: [CodexTimestampedTotals] = []
        var warnedAboutUnparsedTimestamp = false

        func parsedSnapshotDate(timestamp: String) -> Date? {
            let date = Self.dateFromTimestamp(timestamp)
            if date == nil, !warnedAboutUnparsedTimestamp {
                warnedAboutUnparsedTimestamp = true
                self.log.warning(
                    "Codex cost usage could not parse parent token snapshot timestamp; "
                        + "falling back to lexical comparison",
                    metadata: ["path": fileURL.path, "timestamp": timestamp])
            }
            return date
        }

        do {
            _ = try CostUsageJsonl.scan(
                fileURL: fileURL,
                maxLineBytes: 512 * 1024,
                prefixBytes: 512 * 1024,
                onLine: { line in
                    guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                    autoreleasepool {
                        guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any]
                        else { return }

                        if obj["type"] as? String == "session_meta" {
                            let payload = obj["payload"] as? [String: Any]
                            if sessionId == nil {
                                sessionId = payload?["session_id"] as? String
                                    ?? payload?["sessionId"] as? String
                                    ?? payload?["id"] as? String
                                    ?? obj["session_id"] as? String
                                    ?? obj["sessionId"] as? String
                                    ?? obj["id"] as? String
                            }
                            return
                        }

                        guard obj["type"] as? String == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        guard payload["type"] as? String == "token_count" else { return }
                        guard let info = payload["info"] as? [String: Any] else { return }
                        guard let timestamp = obj["timestamp"] as? String else { return }

                        func toInt(_ value: Any?) -> Int {
                            if let number = value as? NSNumber { return number.intValue }
                            return 0
                        }

                        let total = info["total_token_usage"] as? [String: Any]
                        let last = info["last_token_usage"] as? [String: Any]

                        if let last {
                            let rawDelta = CostUsageCodexTotals(
                                input: max(0, toInt(last["input_tokens"])),
                                cached: max(0, toInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"])),
                                output: max(0, toInt(last["output_tokens"])))
                            let base = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            let next = Self.codexAddTotals(base, rawDelta)
                            previousTotals = next

                            if let total {
                                let rawTotals = CostUsageCodexTotals(
                                    input: toInt(total["input_tokens"]),
                                    cached: toInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"]),
                                    output: toInt(total["output_tokens"]))
                                rawTotalsBaseline = rawTotals
                                if !Self.codexTotalsEqual(rawTotals, next) {
                                    sawDivergentTotals = true
                                }
                            } else {
                                rawTotalsBaseline = next
                            }

                            snapshots.append(CodexTimestampedTotals(
                                timestamp: timestamp,
                                date: parsedSnapshotDate(timestamp: timestamp),
                                totals: next))
                        } else if let total {
                            let next = CostUsageCodexTotals(
                                input: toInt(total["input_tokens"]),
                                cached: toInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"]),
                                output: toInt(total["output_tokens"]))
                            let delta = sawDivergentTotals
                                ? Self.codexDivergentTotalDelta(
                                    rawBaseline: rawTotalsBaseline,
                                    countedBaseline: previousTotals,
                                    current: next)
                                : Self.codexTotalDelta(from: rawTotalsBaseline, to: next)
                            let base = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            let countedTotals = Self.codexAddTotals(base, delta)
                            previousTotals = countedTotals
                            rawTotalsBaseline = next
                            if !Self.codexTotalsEqual(next, countedTotals) {
                                sawDivergentTotals = true
                            }
                            snapshots.append(CodexTimestampedTotals(
                                timestamp: timestamp,
                                date: parsedSnapshotDate(timestamp: timestamp),
                                totals: countedTotals))
                        }
                    }
                })
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning parent token snapshots",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
        }

        return (sessionId, snapshots)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialHasDivergentTotals: Bool = false,
        initialCodexTurnID: String? = nil,
        inheritedTotalsResolver: ((String, String) -> CostUsageCodexTotals?)? = nil) -> CodexParseResult
    {
        var currentModel = initialModel
        var previousTotals = initialTotals
        var sessionId: String?
        var forkedFromId: String?
        var inheritedTotals: CostUsageCodexTotals?
        var remainingInheritedTotals: CostUsageCodexTotals?
        var currentTurnID = initialCodexTurnID
        var rawTotalsBaseline = initialRawTotalsBaseline ?? initialTotals
        var sawDivergentTotals = initialHasDivergentTotals

        var days: [String: [String: [Int]]] = [:]
        var rows: [CodexUsageRow] = []

        func add(dayKey: String, model: String, input: Int, cached: Int, output: Int) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeCodexModel(model)

            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + input
            packed[1] = (packed[safe: 1] ?? 0) + cached
            packed[2] = (packed[safe: 2] ?? 0) + output
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        let maxLineBytes = 256 * 1024
        let prefixBytes = maxLineBytes

        if startOffset == 0,
           let metadata = Self.parseCodexSessionMetadata(fileURL: fileURL)
        {
            sessionId = metadata.sessionId
            forkedFromId = metadata.forkedFromId
            if let forkedFromId = metadata.forkedFromId,
               inheritedTotals == nil
            {
                let forkedAt = metadata.forkTimestamp ?? ""
                inheritedTotals = inheritedTotalsResolver?(forkedFromId, forkedAt)
                remainingInheritedTotals = inheritedTotals
            }
        }

        let parsedBytes: Int64
        do {
            parsedBytes = try CostUsageJsonl.scan(
                fileURL: fileURL,
                offset: startOffset,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                onLine: { line in
                    guard !line.bytes.isEmpty else { return }
                    if line.wasTruncated {
                        // `turn_context` can carry very large prompts, but its model usually appears near the start.
                        if let model = Self.extractCodexTurnContextModel(from: line.bytes) {
                            currentModel = model
                        }
                        return
                    }

                    guard
                        line.bytes.containsAscii(#""type":"event_msg""#)
                        || line.bytes.containsAscii(#""type":"turn_context""#)
                        || line.bytes.containsAscii(#""type":"session_meta""#)
                    else { return }

                    if line.bytes.containsAscii(#""type":"event_msg""#),
                       !line.bytes.containsAscii(#""token_count""#),
                       !line.bytes.containsAscii(#""task_started""#)
                    {
                        return
                    }

                    autoreleasepool {
                        guard
                            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                            let type = obj["type"] as? String
                        else { return }

                        if type == "session_meta" {
                            let payload = obj["payload"] as? [String: Any]
                            if sessionId == nil {
                                sessionId = payload?["session_id"] as? String
                                    ?? payload?["sessionId"] as? String
                                    ?? payload?["id"] as? String
                                    ?? obj["session_id"] as? String
                                    ?? obj["sessionId"] as? String
                                    ?? obj["id"] as? String
                            }
                            if forkedFromId == nil {
                                forkedFromId = payload?["forked_from_id"] as? String
                                    ?? payload?["forkedFromId"] as? String
                                    ?? payload?["parent_session_id"] as? String
                                    ?? payload?["parentSessionId"] as? String
                            }
                            if inheritedTotals == nil, let forkedFromId {
                                let forkedAt = payload?["timestamp"] as? String
                                    ?? obj["timestamp"] as? String
                                    ?? ""
                                inheritedTotals = inheritedTotalsResolver?(forkedFromId, forkedAt)
                                remainingInheritedTotals = inheritedTotals
                            }
                            return
                        }

                        guard let tsText = obj["timestamp"] as? String else { return }
                        guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText)
                        else { return }

                        if type == "turn_context" {
                            if let payload = obj["payload"] as? [String: Any] {
                                if let model = payload["model"] as? String {
                                    currentModel = model
                                } else if let info = payload["info"] as? [String: Any],
                                          let model = info["model"] as? String
                                {
                                    currentModel = model
                                }
                            }
                            return
                        }

                        guard type == "event_msg" else { return }
                        guard let payload = obj["payload"] as? [String: Any] else { return }
                        if (payload["type"] as? String) == "task_started" {
                            currentTurnID = Self.codexTurnID(from: payload)
                            return
                        }
                        guard (payload["type"] as? String) == "token_count" else { return }

                        let info = payload["info"] as? [String: Any]
                        let modelFromInfo = info?["model"] as? String
                            ?? info?["model_name"] as? String
                            ?? payload["model"] as? String
                            ?? obj["model"] as? String
                        let model = currentModel ?? modelFromInfo ?? "gpt-5"

                        func toInt(_ v: Any?) -> Int {
                            if let n = v as? NSNumber { return n.intValue }
                            return 0
                        }

                        let total = (info?["total_token_usage"] as? [String: Any])
                        let last = (info?["last_token_usage"] as? [String: Any])

                        var deltaInput = 0
                        var deltaCached = 0
                        var deltaOutput = 0

                        func adjustedLastDelta(_ rawDelta: CostUsageCodexTotals) -> CostUsageCodexTotals {
                            guard var remaining = remainingInheritedTotals else { return rawDelta }

                            let adjusted = CostUsageCodexTotals(
                                input: max(0, rawDelta.input - remaining.input),
                                cached: max(0, rawDelta.cached - remaining.cached),
                                output: max(0, rawDelta.output - remaining.output))

                            remaining.input = max(0, remaining.input - rawDelta.input)
                            remaining.cached = max(0, remaining.cached - rawDelta.cached)
                            remaining.output = max(0, remaining.output - rawDelta.output)
                            remainingInheritedTotals = if remaining.input == 0, remaining.cached == 0,
                                                          remaining.output == 0
                            {
                                nil
                            } else {
                                remaining
                            }

                            return adjusted
                        }

                        if let last {
                            let rawDelta = CostUsageCodexTotals(
                                input: max(0, toInt(last["input_tokens"])),
                                cached: max(0, toInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"])),
                                output: max(0, toInt(last["output_tokens"])))
                            let adjustedDelta = adjustedLastDelta(rawDelta)
                            deltaInput = adjustedDelta.input
                            deltaCached = adjustedDelta.cached
                            deltaOutput = adjustedDelta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            let countedTotals = Self.codexAddTotals(prev, adjustedDelta)
                            previousTotals = countedTotals

                            if let total {
                                let rawTotals = CostUsageCodexTotals(
                                    input: toInt(total["input_tokens"]),
                                    cached: toInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"]),
                                    output: toInt(total["output_tokens"]))
                                let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                                    CostUsageCodexTotals(
                                        input: max(0, rawTotals.input - inheritedTotals.input),
                                        cached: max(0, rawTotals.cached - inheritedTotals.cached),
                                        output: max(0, rawTotals.output - inheritedTotals.output))
                                } else {
                                    rawTotals
                                }
                                rawTotalsBaseline = currentTotals
                                if !Self.codexTotalsEqual(currentTotals, countedTotals) {
                                    sawDivergentTotals = true
                                }
                            } else {
                                rawTotalsBaseline = countedTotals
                            }
                        } else if let total {
                            let rawTotals = CostUsageCodexTotals(
                                input: toInt(total["input_tokens"]),
                                cached: toInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"]),
                                output: toInt(total["output_tokens"]))

                            let currentTotals: CostUsageCodexTotals = if let inheritedTotals {
                                CostUsageCodexTotals(
                                    input: max(0, rawTotals.input - inheritedTotals.input),
                                    cached: max(0, rawTotals.cached - inheritedTotals.cached),
                                    output: max(0, rawTotals.output - inheritedTotals.output))
                            } else {
                                rawTotals
                            }

                            let delta = sawDivergentTotals
                                ? Self.codexDivergentTotalDelta(
                                    rawBaseline: rawTotalsBaseline,
                                    countedBaseline: previousTotals,
                                    current: currentTotals)
                                : Self.codexTotalDelta(from: rawTotalsBaseline, to: currentTotals)
                            deltaInput = delta.input
                            deltaCached = delta.cached
                            deltaOutput = delta.output
                            let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                            previousTotals = Self.codexAddTotals(prev, delta)
                            rawTotalsBaseline = currentTotals
                            if !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals) {
                                sawDivergentTotals = true
                            }
                            remainingInheritedTotals = nil
                        } else {
                            return
                        }

                        if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
                        let cachedClamp = min(deltaCached, deltaInput)
                        let normModel = CostUsagePricing.normalizeCodexModel(model)
                        add(
                            dayKey: dayKey,
                            model: normModel,
                            input: deltaInput,
                            cached: cachedClamp,
                            output: deltaOutput)
                        if CostUsageDayRange.isInRange(
                            dayKey: dayKey,
                            since: range.scanSinceKey,
                            until: range.scanUntilKey)
                        {
                            rows.append(CodexUsageRow(
                                day: dayKey,
                                model: normModel,
                                turnID: Self.codexTurnID(from: payload) ?? currentTurnID,
                                input: deltaInput,
                                cached: cachedClamp,
                                output: deltaOutput))
                        }
                    }
                })
        } catch {
            self.log.warning(
                "Codex cost usage failed while scanning session file",
                metadata: ["path": fileURL.path, "error": error.localizedDescription])
            parsedBytes = startOffset
        }

        return CodexParseResult(
            days: days,
            parsedBytes: parsedBytes,
            lastModel: currentModel,
            lastTotals: sawDivergentTotals && !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals)
                ? nil
                : previousTotals,
            lastCountedTotals: previousTotals,
            lastRawTotalsBaseline: rawTotalsBaseline,
            hasDivergentTotals: sawDivergentTotals && !Self.codexTotalsEqual(rawTotalsBaseline, previousTotals),
            lastCodexTurnID: currentTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            rows: rows)
    }

    private static func codexTurnID(from payload: [String: Any]) -> String? {
        if let turnID = payload["turn_id"] as? String ?? payload["turnId"] as? String ?? payload["id"] as? String {
            return turnID
        }
        if let info = payload["info"] as? [String: Any] {
            return info["turn_id"] as? String ?? info["turnId"] as? String ?? info["id"] as? String
        }
        return nil
    }

    private static func scanCodexFile(
        fileURL: URL,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState)
    {
        let metadata = Self.codexFileMetadata(fileURL: fileURL)
        if let fileId = metadata.fileId, state.seenFileIds.contains(fileId) {
            Self.dropCachedCodexFile(path: metadata.path, cached: cache.files[metadata.path], cache: &cache)
            return
        }

        let cached = cache.files[metadata.path]
        if let cachedSessionId = cached?.sessionId, state.seenSessionIds.contains(cachedSessionId) {
            Self.dropCachedCodexFile(path: metadata.path, cached: cached, cache: &cache)
            return
        }

        let input = CodexFileScanInput(fileURL: fileURL, metadata: metadata, cached: cached)
        if Self.keepCachedCodexFileIfFresh(input: input, context: context, cache: &cache, state: &state) {
            return
        }
        if Self.appendCodexFileIncrementIfPossible(input: input, context: context, cache: &cache, state: &state) {
            return
        }
        Self.rescanCodexFile(input: input, context: context, cache: &cache, state: &state)
    }

    private static func makeCodexRefreshPlan(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        now: Date,
        nowMs: Int64,
        options: Options) -> CodexRefreshPlan
    {
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let roots = self.codexSessionsRoots(options: options)
        let rootsFingerprint = Self.codexRootsFingerprint(roots)
        let rootsChanged = cache.roots != rootsFingerprint
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let needsCostCacheMigration = cache.files.values.contains { Self.needsCodexCostCache($0, range: range) }
        let modelsDevLoad = ModelsDevCache.load(now: now, cacheRoot: options.cacheRoot)
        let modelsDevCatalog = modelsDevLoad.artifact?.catalog
        let codexPricingKey = Self.codexPricingKey(modelsDevArtifact: modelsDevLoad.artifact)
        let codexPriorityMetadataKey = Self.codexPriorityMetadataKey(databaseURL: options.codexTraceDatabaseURL)
        let hasPriorityMetadata = codexPriorityMetadataKey.hasPrefix("sqlite:")
        let pricingChanged = cache.codexPricingKey != nil && cache.codexPricingKey != codexPricingKey
        let priorityMetadataChanged = Self.codexPriorityMetadataChanged(
            old: cache.codexPriorityMetadataKey,
            new: codexPriorityMetadataKey)
        let needsTurnIDCacheMigration = hasPriorityMetadata && cache.files.values.contains {
            $0.codexTurnIDs == nil && $0.touchesCodexScanWindow(
                sinceKey: range.scanSinceKey,
                untilKey: range.scanUntilKey)
        }
        let shouldInspectPriorityTurns = options.forceRescan
            || windowExpanded
            || rootsChanged
            || needsCostCacheMigration
            || needsTurnIDCacheMigration
            || pricingChanged
            || priorityMetadataChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs
        let priorityTurns = shouldInspectPriorityTurns ? Self.codexPriorityTurns(
            databaseURL: options.codexTraceDatabaseURL,
            sinceDayKey: range.scanSinceKey,
            untilDayKey: range.scanUntilKey) : [:]
        let priorityTurnKeys = Self.codexPriorityTurnKeys(priorityTurns)
        let priorityTurnIDsByDay = Self.codexPriorityTurnIDsByDay(priorityTurns)
        let priorityTurnsChanged = shouldInspectPriorityTurns
            && hasPriorityMetadata
            && Self.codexPriorityTurnKeysChanged(
                old: cache.codexPriorityTurnKeys,
                new: priorityTurnKeys,
                range: range)
        let changedPriorityTurnIDs = shouldInspectPriorityTurns && hasPriorityMetadata
            ? Self.changedPriorityTurnIDs(
                old: cache.codexPriorityTurnIDsByDay,
                new: priorityTurnIDsByDay,
                range: range)
            : []
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || rootsChanged
            || needsCostCacheMigration
            || needsTurnIDCacheMigration
            || pricingChanged
            || priorityMetadataChanged
            || priorityTurnsChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        return CodexRefreshPlan(
            refreshMs: refreshMs,
            roots: roots,
            rootsFingerprint: rootsFingerprint,
            rootsChanged: rootsChanged,
            windowExpanded: windowExpanded,
            needsCostCacheMigration: needsCostCacheMigration,
            modelsDevCatalog: modelsDevCatalog,
            codexPricingKey: codexPricingKey,
            codexPriorityMetadataKey: codexPriorityMetadataKey,
            hasPriorityMetadata: hasPriorityMetadata,
            priorityTurns: priorityTurns,
            priorityTurnKeys: priorityTurnKeys,
            priorityTurnIDsByDay: priorityTurnIDsByDay,
            pricingChanged: pricingChanged,
            priorityMetadataChanged: priorityMetadataChanged,
            priorityTurnsChanged: priorityTurnsChanged,
            needsTurnIDCacheMigration: needsTurnIDCacheMigration,
            changedPriorityTurnIDs: changedPriorityTurnIDs,
            shouldRefresh: shouldRefresh)
    }

    private static func loadCodexDaily(range: CostUsageDayRange, now: Date, options: Options) -> CostUsageDailyReport {
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let plan = Self.makeCodexRefreshPlan(cache: cache, range: range, now: now, nowMs: nowMs, options: options)

        if plan.shouldRefresh {
            if options.forceRescan {
                cache = CostUsageCache()
            }

            let cachedSinceKey = cache.scanSinceKey
            let cachedUntilKey = cache.scanUntilKey
            let shouldRunColdCacheLookback = cache.files.isEmpty || plan.rootsChanged
            let coldCacheLookbackStart = Self.parseDayKey(range.scanSinceKey)
                .map { Calendar.current.startOfDay(for: $0) }
            var seenPaths: Set<String> = []
            var files: [URL] = []
            for root in plan.roots {
                let rootFiles = Self.listCodexSessionFiles(
                    root: root,
                    scanSinceKey: range.scanSinceKey,
                    scanUntilKey: range.scanUntilKey,
                    includeRecursive: options.forceRescan)
                for fileURL in rootFiles.sorted(by: { $0.path < $1.path }) where !seenPaths.contains(fileURL.path) {
                    seenPaths.insert(fileURL.path)
                    files.append(fileURL)
                }

                if shouldRunColdCacheLookback, let coldCacheLookbackStart {
                    let recentlyModifiedFiles = Self.listCodexRecentlyModifiedFiles(
                        root: root,
                        scanSinceKey: range.scanSinceKey,
                        scanUntilKey: range.scanUntilKey,
                        modifiedSince: coldCacheLookbackStart)
                    for fileURL in recentlyModifiedFiles.sorted(by: { $0.path < $1.path })
                        where !seenPaths.contains(fileURL.path)
                    {
                        seenPaths.insert(fileURL.path)
                        files.append(fileURL)
                    }
                }
            }

            for fileURL in Self.cachedCodexSessionFiles(cache: cache, range: range, roots: plan.roots)
                .sorted(by: { $0.path < $1.path })
                where !seenPaths.contains(fileURL.path)
            {
                seenPaths.insert(fileURL.path)
                files.append(fileURL)
            }

            let filePathsInScan = Set(files.map(\.path))

            var scanState = CodexScanState()
            let fileIndex = CodexSessionFileIndex(
                files: files,
                roots: plan.roots,
                cachedSessionFiles: Self.cachedCodexSessionIndex(cache: cache, roots: plan.roots))
            let inheritedResolver = CodexInheritedTotalsResolver(fileIndex: fileIndex)
            let resources = CodexScanResources(
                fileIndex: fileIndex,
                inheritedResolver: inheritedResolver,
                modelsDevCatalog: plan.modelsDevCatalog,
                modelsDevCacheRoot: options.cacheRoot,
                priorityTurns: plan.priorityTurns)
            for fileURL in files {
                Self.scanCodexFile(
                    fileURL: fileURL,
                    context: CodexFileScanContext(
                        range: range,
                        forceFullScan: options
                            .forceRescan || plan.windowExpanded || plan.pricingChanged || plan.priorityMetadataChanged,
                        dropDeferredCodexRows: options.forceRescan || plan.pricingChanged || plan
                            .priorityMetadataChanged
                            || plan.needsTurnIDCacheMigration,
                        requiresTurnIDCache: plan.needsTurnIDCacheMigration,
                        changedPriorityTurnIDs: plan.changedPriorityTurnIDs,
                        resources: resources),
                    cache: &cache,
                    state: &scanState)
            }

            Self.pruneForceRescanFilesOutsideWindow(
                cache: &cache,
                range: range,
                isForceRescan: options.forceRescan)

            let shouldDropAllUnscannedFiles = options.forceRescan || plan.rootsChanged || cache.files.isEmpty
            for key in cache.files.keys where !filePathsInScan.contains(key) {
                guard let old = cache.files[key] else { continue }
                let shouldDrop = shouldDropAllUnscannedFiles ||
                    old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
                guard shouldDrop else { continue }
                Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                cache.files.removeValue(forKey: key)
            }

            if !shouldDropAllUnscannedFiles {
                for key in cache.files.keys {
                    guard let old = cache.files[key] else { continue }
                    guard old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
                    else { continue }
                    guard FileManager.default.fileExists(atPath: key) else {
                        Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                        cache.files.removeValue(forKey: key)
                        continue
                    }
                }
            }

            let shouldRetainWiderWindow = !options.forceRescan && !plan.pricingChanged && !plan
                .priorityMetadataChanged && !plan.needsTurnIDCacheMigration
            let retainedSinceKey = shouldRetainWiderWindow
                ? [cachedSinceKey, range.scanSinceKey].compactMap(\.self).min() ?? range.scanSinceKey
                : range.scanSinceKey
            let retainedUntilKey = shouldRetainWiderWindow
                ? [cachedUntilKey, range.scanUntilKey].compactMap(\.self).max() ?? range.scanUntilKey
                : range.scanUntilKey
            Self.pruneDays(cache: &cache, sinceKey: retainedSinceKey, untilKey: retainedUntilKey)
            cache.roots = plan.rootsFingerprint
            cache.scanSinceKey = retainedSinceKey
            cache.scanUntilKey = retainedUntilKey
            cache.codexPricingKey = plan.codexPricingKey
            cache.codexPriorityMetadataKey = plan.codexPriorityMetadataKey
            if plan.hasPriorityMetadata {
                cache.codexPriorityTurnKeys = Self.mergePriorityTurnKeys(
                    existing: shouldRetainWiderWindow ? cache.codexPriorityTurnKeys : nil,
                    new: plan.priorityTurnKeys,
                    range: range,
                    retainedSinceKey: retainedSinceKey,
                    retainedUntilKey: retainedUntilKey)
                cache.codexPriorityTurnIDsByDay = Self.mergePriorityTurnIDsByDay(
                    existing: shouldRetainWiderWindow ? cache.codexPriorityTurnIDsByDay : nil,
                    new: plan.priorityTurnIDsByDay,
                    range: range,
                    retainedSinceKey: retainedSinceKey,
                    retainedUntilKey: retainedUntilKey)
            }
            cache.lastScanUnixMs = nowMs
            CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: options.cacheRoot)
        }

        return Self.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: plan.modelsDevCatalog,
            modelsDevCacheRoot: options.cacheRoot,
            priorityTurns: plan.priorityTurns)
    }
}

// swiftlint:enable type_body_length
