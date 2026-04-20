import Foundation

// swiftlint:disable type_body_length
enum CostUsageScanner {
    private static let log = CodexBarLog.logger(LogCategories.tokenCost)

    enum ClaudeLogProviderFilter {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options {
        var codexSessionsRoot: URL?
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        var refreshMinIntervalSeconds: TimeInterval = 60
        var claudeLogProviderFilter: ClaudeLogProviderFilter = .all
        /// Force a full rescan, ignoring per-file cache and incremental offsets.
        var forceRescan: Bool = false

        init(
            codexSessionsRoot: URL? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            claudeLogProviderFilter: ClaudeLogProviderFilter = .all,
            forceRescan: Bool = false)
        {
            self.codexSessionsRoot = codexSessionsRoot
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.claudeLogProviderFilter = claudeLogProviderFilter
            self.forceRescan = forceRescan
        }
    }

    struct CodexParseResult {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
        let lastModel: String?
        let lastTotals: CostUsageCodexTotals?
        let sessionId: String?
        let forkedFromId: String?
    }

    private struct CodexScanState {
        var seenSessionIds: Set<String> = []
        var seenFileIds: Set<String> = []
    }

    private struct CodexTimestampedTotals {
        let timestamp: String
        let date: Date?
        let totals: CostUsageCodexTotals
    }

    private struct CodexScanResources {
        let fileIndex: CodexSessionFileIndex
        let inheritedResolver: CodexInheritedTotalsResolver
    }

    private final class CodexSessionFileIndex {
        private let files: [URL]
        private let roots: [URL]
        private var nextUnindexedFile = 0
        private var fileURLBySessionId: [String: URL] = [:]
        private var missingSessionIds: Set<String> = []

        init(files: [URL], roots: [URL], cachedSessionFiles: [String: URL] = [:]) {
            self.files = files
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

            for root in self.roots {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
                    if self.files.contains(where: { $0.path == fileURL.path }) {
                        continue
                    }
                    guard let indexedSessionId = CostUsageScanner.parseCodexSessionIdentifier(fileURL: fileURL) else {
                        continue
                    }
                    self.fileURLBySessionId[indexedSessionId] = fileURL
                    if indexedSessionId == sessionId {
                        return fileURL
                    }
                }
            }

            self.missingSessionIds.insert(sessionId)
            return nil
        }
    }

    private final class CodexInheritedTotalsResolver {
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
        case .zai, .gemini, .antigravity, .cursor, .opencode, .opencodego, .alibaba, .factory, .copilot,
             .minimax, .kilo, .kiro, .kimi,
             .kimik2, .augment, .jetbrains, .amp, .ollama, .synthetic, .openrouter, .warp, .perplexity, .abacus:
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
        let recursive = includeRecursive ? self.listCodexSessionFilesRecursive(root: root) : []
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

    private static func listCodexRecentlyModifiedFiles(root: URL, modifiedSince: Date) -> [URL] {
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

    private static func listCodexSessionFilesRecursive(root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            out.append(item)
        }
        return out
    }

    private static let codexFilenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    private static func dayKeyFromFilename(_ filename: String) -> String? {
        guard let regex = self.codexFilenameDateRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range) else { return nil }
        guard let matchRange = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[matchRange])
    }

    private static func fileIdentityString(fileURL: URL) -> String? {
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
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { return nil }
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

                    if let total = info["total_token_usage"] as? [String: Any] {
                        let next = CostUsageCodexTotals(
                            input: toInt(total["input_tokens"]),
                            cached: toInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"]),
                            output: toInt(total["output_tokens"]))
                        previousTotals = next
                        snapshots.append(CodexTimestampedTotals(
                            timestamp: timestamp,
                            date: parsedSnapshotDate(timestamp: timestamp),
                            totals: next))
                    } else if let last = info["last_token_usage"] as? [String: Any] {
                        let base = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                        let next = CostUsageCodexTotals(
                            input: base.input + toInt(last["input_tokens"]),
                            cached: base.cached + toInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"]),
                            output: base.output + toInt(last["output_tokens"]))
                        previousTotals = next
                        snapshots.append(CodexTimestampedTotals(
                            timestamp: timestamp,
                            date: parsedSnapshotDate(timestamp: timestamp),
                            totals: next))
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
        inheritedTotalsResolver: ((String, String) -> CostUsageCodexTotals?)? = nil) -> CodexParseResult
    {
        var currentModel = initialModel
        var previousTotals = initialTotals
        var sessionId: String?
        var forkedFromId: String?
        var inheritedTotals: CostUsageCodexTotals?
        var remainingInheritedTotals: CostUsageCodexTotals?

        var days: [String: [String: [Int]]] = [:]

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
        let prefixBytes = 32 * 1024

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
                    guard !line.wasTruncated else { return }

                    guard
                        line.bytes.containsAscii(#""type":"event_msg""#)
                        || line.bytes.containsAscii(#""type":"turn_context""#)
                        || line.bytes.containsAscii(#""type":"session_meta""#)
                    else { return }

                    if line.bytes.containsAscii(#""type":"event_msg""#), !line.bytes.containsAscii(#""token_count""#) {
                        return
                    }

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
                    guard (payload["type"] as? String) == "token_count" else { return }

                    let info = payload["info"] as? [String: Any]
                    let modelFromInfo = info?["model"] as? String
                        ?? info?["model_name"] as? String
                        ?? payload["model"] as? String
                        ?? obj["model"] as? String
                    let model = modelFromInfo ?? currentModel ?? "gpt-5"

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

                        let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                        deltaInput = max(0, currentTotals.input - prev.input)
                        deltaCached = max(0, currentTotals.cached - prev.cached)
                        deltaOutput = max(0, currentTotals.output - prev.output)
                        previousTotals = currentTotals
                        remainingInheritedTotals = nil
                    } else if let last {
                        let rawDelta = CostUsageCodexTotals(
                            input: max(0, toInt(last["input_tokens"])),
                            cached: max(0, toInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"])),
                            output: max(0, toInt(last["output_tokens"])))
                        let adjustedDelta = adjustedLastDelta(rawDelta)
                        deltaInput = adjustedDelta.input
                        deltaCached = adjustedDelta.cached
                        deltaOutput = adjustedDelta.output
                        let prev = previousTotals ?? .init(input: 0, cached: 0, output: 0)
                        previousTotals = CostUsageCodexTotals(
                            input: prev.input + deltaInput,
                            cached: prev.cached + deltaCached,
                            output: prev.output + deltaOutput)
                    } else {
                        return
                    }

                    if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
                    let cachedClamp = min(deltaCached, deltaInput)
                    add(dayKey: dayKey, model: model, input: deltaInput, cached: cachedClamp, output: deltaOutput)
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
            lastTotals: previousTotals,
            sessionId: sessionId,
            forkedFromId: forkedFromId)
    }

    private static func scanCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        resources: CodexScanResources)
    {
        let path = fileURL.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtimeMs = Int64(mtime * 1000)
        let fileId = Self.fileIdentityString(fileURL: fileURL)

        func dropCachedFile(_ cached: CostUsageFileUsage?) {
            if let cached {
                Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
            }
            cache.files.removeValue(forKey: path)
        }

        if let fileId, state.seenFileIds.contains(fileId) {
            dropCachedFile(cache.files[path])
            return
        }

        let cached = cache.files[path]
        if let cachedSessionId = cached?.sessionId, state.seenSessionIds.contains(cachedSessionId) {
            dropCachedFile(cached)
            return
        }

        let needsSessionId = cached != nil && cached?.sessionId == nil
        if let cached,
           cached.mtimeUnixMs == mtimeMs,
           cached.size == size,
           !needsSessionId
        {
            if let cachedSessionId = cached.sessionId {
                state.seenSessionIds.insert(cachedSessionId)
            }
            if let fileId {
                state.seenFileIds.insert(fileId)
            }
            return
        }

        if let cached, cached.sessionId != nil {
            let startOffset = cached.parsedBytes ?? cached.size
            let canIncremental = size > cached.size && startOffset > 0 && startOffset <= size
                && cached.lastTotals != nil
                && cached.forkedFromId == nil
            if canIncremental {
                let delta = Self.parseCodexFile(
                    fileURL: fileURL,
                    range: range,
                    startOffset: startOffset,
                    initialModel: cached.lastModel,
                    initialTotals: cached.lastTotals)
                let sessionId = delta.sessionId ?? cached.sessionId
                if let sessionId, state.seenSessionIds.contains(sessionId) {
                    dropCachedFile(cached)
                    return
                }

                if !delta.days.isEmpty {
                    Self.applyFileDays(cache: &cache, fileDays: delta.days, sign: 1)
                }

                var mergedDays = cached.days
                Self.mergeFileDays(existing: &mergedDays, delta: delta.days)
                cache.files[path] = Self.makeFileUsage(
                    mtimeUnixMs: mtimeMs,
                    size: size,
                    days: mergedDays,
                    parsedBytes: delta.parsedBytes,
                    lastModel: delta.lastModel,
                    lastTotals: delta.lastTotals,
                    sessionId: sessionId,
                    forkedFromId: delta.forkedFromId ?? cached.forkedFromId)
                if let sessionId {
                    state.seenSessionIds.insert(sessionId)
                    resources.fileIndex.remember(fileURL: fileURL, sessionId: sessionId)
                }
                if let fileId {
                    state.seenFileIds.insert(fileId)
                }
                return
            }
        }

        if let cached {
            Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }

        let parsed = Self.parseCodexFile(
            fileURL: fileURL,
            range: range,
            inheritedTotalsResolver: resources.inheritedResolver.inheritedTotals(for:atOrBefore:))
        let sessionId = parsed.sessionId ?? cached?.sessionId
        if let sessionId, state.seenSessionIds.contains(sessionId) {
            cache.files.removeValue(forKey: path)
            return
        }

        let usage = Self.makeFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            days: parsed.days,
            parsedBytes: parsed.parsedBytes,
            lastModel: parsed.lastModel,
            lastTotals: parsed.lastTotals,
            sessionId: sessionId,
            forkedFromId: parsed.forkedFromId)
        cache.files[path] = usage
        Self.applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
        if let sessionId {
            state.seenSessionIds.insert(sessionId)
            resources.fileIndex.remember(fileURL: fileURL, sessionId: sessionId)
        }
        if let fileId {
            state.seenFileIds.insert(fileId)
        }
    }

    private static func loadCodexDaily(range: CostUsageDayRange, now: Date, options: Options) -> CostUsageDailyReport {
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let shouldRefresh = options.forceRescan
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        if shouldRefresh {
            if options.forceRescan {
                cache = CostUsageCache()
            }

            let roots = self.codexSessionsRoots(options: options)
            let includeRecursive = options.forceRescan
            let rootsFingerprint = Self.codexRootsFingerprint(roots)
            let rootsChanged = cache.roots != nil && cache.roots != rootsFingerprint
            let shouldRunColdCacheLookback = cache.files.isEmpty || rootsChanged
            let coldCacheLookbackStart = Self.parseDayKey(range.scanSinceKey)
                .map { Calendar.current.startOfDay(for: $0) }
            var seenPaths: Set<String> = []
            var files: [URL] = []
            for root in roots {
                let rootFiles = Self.listCodexSessionFiles(
                    root: root,
                    scanSinceKey: range.scanSinceKey,
                    scanUntilKey: range.scanUntilKey,
                    includeRecursive: includeRecursive)
                for fileURL in rootFiles.sorted(by: { $0.path < $1.path }) where !seenPaths.contains(fileURL.path) {
                    seenPaths.insert(fileURL.path)
                    files.append(fileURL)
                }

                if !includeRecursive, shouldRunColdCacheLookback, let coldCacheLookbackStart {
                    let recentlyModifiedFiles = Self.listCodexRecentlyModifiedFiles(
                        root: root,
                        modifiedSince: coldCacheLookbackStart)
                    for fileURL in recentlyModifiedFiles.sorted(by: { $0.path < $1.path })
                        where !seenPaths.contains(fileURL.path)
                    {
                        seenPaths.insert(fileURL.path)
                        files.append(fileURL)
                    }
                }
            }

            for fileURL in Self.cachedCodexSessionFiles(cache: cache, range: range, roots: roots)
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
                roots: includeRecursive ? [] : roots,
                cachedSessionFiles: Self.cachedCodexSessionIndex(cache: cache, roots: roots))
            let inheritedResolver = CodexInheritedTotalsResolver(fileIndex: fileIndex)
            let resources = CodexScanResources(
                fileIndex: fileIndex,
                inheritedResolver: inheritedResolver)
            for fileURL in files {
                Self.scanCodexFile(
                    fileURL: fileURL,
                    range: range,
                    cache: &cache,
                    state: &scanState,
                    resources: resources)
            }

            for key in cache.files.keys where !filePathsInScan.contains(key) {
                if let old = cache.files[key] {
                    Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                }
                cache.files.removeValue(forKey: key)
            }

            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.roots = rootsFingerprint
            cache.lastScanUnixMs = nowMs
            CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: options.cacheRoot)
        }

        return Self.buildCodexReportFromCache(cache: cache, range: range)
    }

    private static func buildCodexReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> CostUsageDailyReport
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalTokens = 0
        var totalCost: Double = 0
        var costSeen = false

        let dayKeys = cache.days.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        for day in dayKeys {
            guard let models = cache.days[day] else { continue }
            let modelNames = models.keys.sorted()

            var dayInput = 0
            var dayOutput = 0

            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for model in modelNames {
                let packed = models[model] ?? [0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cached = packed[safe: 1] ?? 0
                let output = packed[safe: 2] ?? 0
                let totalTokens = input + output

                dayInput += input
                dayOutput += output

                let cost = CostUsagePricing.codexCostUSD(
                    model: model,
                    inputTokens: input,
                    cachedInputTokens: cached,
                    outputTokens: output)
                breakdown.append(
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: cost,
                        totalTokens: totalTokens))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let sortedBreakdown = Self.sortedModelBreakdowns(breakdown)

            let dayTotal = dayInput + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: sortedBreakdown))

            totalInput += dayInput
            totalOutput += dayOutput
            totalTokens += dayTotal
            if let entryCost {
                totalCost += entryCost
                costSeen = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                totalTokens: totalTokens,
                totalCostUSD: costSeen ? totalCost : nil)

        return CostUsageDailyReport(data: entries, summary: summary)
    }

    // MARK: - Shared cache mutations

    static func makeFileUsage(
        mtimeUnixMs: Int64,
        size: Int64,
        days: [String: [String: [Int]]],
        parsedBytes: Int64?,
        lastModel: String? = nil,
        lastTotals: CostUsageCodexTotals? = nil,
        sessionId: String? = nil,
        forkedFromId: String? = nil,
        claudeRows: [ClaudeUsageRow]? = nil) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            mtimeUnixMs: mtimeUnixMs,
            size: size,
            days: days,
            parsedBytes: parsedBytes,
            lastModel: lastModel,
            lastTotals: lastTotals,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            claudeRows: claudeRows)
    }

    static func mergeFileDays(
        existing: inout [String: [String: [Int]]],
        delta: [String: [String: [Int]]])
    {
        for (day, models) in delta {
            var dayModels = existing[day] ?? [:]
            for (model, packed) in models {
                let existingPacked = dayModels[model] ?? []
                let merged = Self.addPacked(a: existingPacked, b: packed, sign: 1)
                if merged.allSatisfy({ $0 == 0 }) {
                    dayModels.removeValue(forKey: model)
                } else {
                    dayModels[model] = merged
                }
            }

            if dayModels.isEmpty {
                existing.removeValue(forKey: day)
            } else {
                existing[day] = dayModels
            }
        }
    }

    static func applyFileDays(cache: inout CostUsageCache, fileDays: [String: [String: [Int]]], sign: Int) {
        for (day, models) in fileDays {
            var dayModels = cache.days[day] ?? [:]
            for (model, packed) in models {
                let existing = dayModels[model] ?? []
                let merged = Self.addPacked(a: existing, b: packed, sign: sign)
                if merged.allSatisfy({ $0 == 0 }) {
                    dayModels.removeValue(forKey: model)
                } else {
                    dayModels[model] = merged
                }
            }

            if dayModels.isEmpty {
                cache.days.removeValue(forKey: day)
            } else {
                cache.days[day] = dayModels
            }
        }
    }

    static func pruneDays(cache: inout CostUsageCache, sinceKey: String, untilKey: String) {
        for key in cache.days.keys where !CostUsageDayRange.isInRange(dayKey: key, since: sinceKey, until: untilKey) {
            cache.days.removeValue(forKey: key)
        }
    }

    static func addPacked(a: [Int], b: [Int], sign: Int) -> [Int] {
        let len = max(a.count, b.count)
        var out: [Int] = Array(repeating: 0, count: len)
        for idx in 0..<len {
            let next = (a[safe: idx] ?? 0) + sign * (b[safe: idx] ?? 0)
            out[idx] = max(0, next)
        }
        return out
    }

    static func sortedModelBreakdowns(_ breakdowns: [CostUsageDailyReport.ModelBreakdown])
        -> [CostUsageDailyReport.ModelBreakdown]
    {
        breakdowns.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }

            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }

            return lhs.modelName > rhs.modelName
        }
    }

    // MARK: - Date parsing

    private static func parseDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard
            let y = Int(parts[0]),
            let m = Int(parts[1]),
            let d = Int(parts[2])
        else { return nil }

        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = 12
        return comps.date
    }
}

// swiftlint:enable type_body_length

extension Data {
    func containsAscii(_ needle: String) -> Bool {
        guard let n = needle.data(using: .utf8) else { return false }
        return self.range(of: n) != nil
    }
}

extension [Int] {
    subscript(safe index: Int) -> Int? {
        if index < 0 { return nil }
        if index >= self.count { return nil }
        return self[index]
    }
}

extension [UInt8] {
    subscript(safe index: Int) -> UInt8? {
        if index < 0 { return nil }
        if index >= self.count { return nil }
        return self[index]
    }
}
