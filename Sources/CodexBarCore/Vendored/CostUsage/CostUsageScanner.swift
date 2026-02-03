import Foundation

enum CostUsageScanner {
    enum ClaudeLogProviderFilter: Sendable {
        case all
        case vertexAIOnly
        case excludeVertexAI
    }

    struct Options: Sendable {
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

    struct CodexParseResult: Sendable {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
        let lastModel: String?
        let lastTotals: CostUsageCodexTotals?
        let sessionId: String?
    }

    private struct CodexScanState {
        var seenSessionIds: Set<String> = []
        var seenFileIds: Set<String> = []
    }

    struct ClaudeParseResult: Sendable {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
    }

    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        let range = CostUsageDayRange(since: since, until: until)

        switch provider {
        case .codex:
            return self.loadCodexDaily(range: range, now: now, options: options)
        case .claude:
            return self.loadClaudeDaily(provider: .claude, range: range, now: now, options: options)
        case .zai:
            return CostUsageDailyReport(data: [], summary: nil)
        case .gemini:
            return CostUsageDailyReport(data: [], summary: nil)
        case .antigravity:
            return CostUsageDailyReport(data: [], summary: nil)
        case .cursor:
            return CostUsageDailyReport(data: [], summary: nil)
        case .opencode:
            return CostUsageDailyReport(data: [], summary: nil)
        case .factory:
            return CostUsageDailyReport(data: [], summary: nil)
        case .copilot:
            return CostUsageDailyReport(data: [], summary: nil)
        case .minimax:
            return CostUsageDailyReport(data: [], summary: nil)
        case .vertexai:
            var filtered = options
            if filtered.claudeLogProviderFilter == .all {
                filtered.claudeLogProviderFilter = .vertexAIOnly
            }
            return self.loadClaudeDaily(provider: .vertexai, range: range, now: now, options: filtered)
        case .kiro:
            return CostUsageDailyReport(data: [], summary: nil)
        case .kimi:
            return CostUsageDailyReport(data: [], summary: nil)
        case .kimik2:
            return CostUsageDailyReport(data: [], summary: nil)
        case .augment:
            return CostUsageDailyReport(data: [], summary: nil)
        case .jetbrains:
            return CostUsageDailyReport(data: [], summary: nil)
        case .amp:
            return CostUsageDailyReport(data: [], summary: nil)
        case .synthetic:
            return CostUsageDailyReport(data: [], summary: nil)
        }
    }

    // MARK: - Day keys

    struct CostUsageDayRange: Sendable {
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

    private static func listCodexSessionFiles(root: URL, scanSinceKey: String, scanUntilKey: String) -> [URL] {
        let partitioned = self.listCodexSessionFilesByDatePartition(
            root: root,
            scanSinceKey: scanSinceKey,
            scanUntilKey: scanUntilKey)
        let flat = self.listCodexSessionFilesFlat(root: root, scanSinceKey: scanSinceKey, scanUntilKey: scanUntilKey)
        var seen: Set<String> = []
        var out: [URL] = []
        for item in partitioned + flat where !seen.contains(item.path) {
            seen.insert(item.path)
            out.append(item)
        }
        return out
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

    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil) -> CodexParseResult
    {
        var currentModel = initialModel
        var previousTotals = initialTotals
        var sessionId: String?

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

        let parsedBytes = (try? CostUsageJsonl.scan(
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
                    if sessionId == nil {
                        let payload = obj["payload"] as? [String: Any]
                        sessionId = payload?["session_id"] as? String
                            ?? payload?["sessionId"] as? String
                            ?? payload?["id"] as? String
                            ?? obj["session_id"] as? String
                            ?? obj["sessionId"] as? String
                            ?? obj["id"] as? String
                    }
                    return
                }

                guard let tsText = obj["timestamp"] as? String else { return }
                guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) else { return }

                if type == "turn_context" {
                    if let payload = obj["payload"] as? [String: Any] {
                        if let model = payload["model"] as? String {
                            currentModel = model
                        } else if let info = payload["info"] as? [String: Any], let model = info["model"] as? String {
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

                if let total {
                    let input = toInt(total["input_tokens"])
                    let cached = toInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"])
                    let output = toInt(total["output_tokens"])

                    let prev = previousTotals
                    deltaInput = max(0, input - (prev?.input ?? 0))
                    deltaCached = max(0, cached - (prev?.cached ?? 0))
                    deltaOutput = max(0, output - (prev?.output ?? 0))
                    previousTotals = CostUsageCodexTotals(input: input, cached: cached, output: output)
                } else if let last {
                    deltaInput = max(0, toInt(last["input_tokens"]))
                    deltaCached = max(0, toInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"]))
                    deltaOutput = max(0, toInt(last["output_tokens"]))
                } else {
                    return
                }

                if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
                let cachedClamp = min(deltaCached, deltaInput)
                add(dayKey: dayKey, model: model, input: deltaInput, cached: cachedClamp, output: deltaOutput)
            })) ?? startOffset

        return CodexParseResult(
            days: days,
            parsedBytes: parsedBytes,
            lastModel: currentModel,
            lastTotals: previousTotals,
            sessionId: sessionId)
    }

    private static func scanCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        cache: inout CostUsageCache,
        state: inout CodexScanState)
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
                    sessionId: sessionId)
                if let sessionId {
                    state.seenSessionIds.insert(sessionId)
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

        let parsed = Self.parseCodexFile(fileURL: fileURL, range: range)
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
            sessionId: sessionId)
        cache.files[path] = usage
        Self.applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
        if let sessionId {
            state.seenSessionIds.insert(sessionId)
        }
        if let fileId {
            state.seenFileIds.insert(fileId)
        }
    }

    private static func loadCodexDaily(range: CostUsageDayRange, now: Date, options: Options) -> CostUsageDailyReport {
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let shouldRefresh = refreshMs == 0 || cache.lastScanUnixMs == 0 || nowMs - cache.lastScanUnixMs > refreshMs

        let roots = self.codexSessionsRoots(options: options)
        var seenPaths: Set<String> = []
        var files: [URL] = []
        for root in roots {
            let rootFiles = Self.listCodexSessionFiles(
                root: root,
                scanSinceKey: range.scanSinceKey,
                scanUntilKey: range.scanUntilKey)
            for fileURL in rootFiles.sorted(by: { $0.path < $1.path }) where !seenPaths.contains(fileURL.path) {
                seenPaths.insert(fileURL.path)
                files.append(fileURL)
            }
        }
        let filePathsInScan = Set(files.map(\.path))

        if shouldRefresh {
            if options.forceRescan {
                cache = CostUsageCache()
            }
            var scanState = CodexScanState()
            for fileURL in files {
                Self.scanCodexFile(
                    fileURL: fileURL,
                    range: range,
                    cache: &cache,
                    state: &scanState)
            }

            for key in cache.files.keys where !filePathsInScan.contains(key) {
                if let old = cache.files[key] {
                    Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                }
                cache.files.removeValue(forKey: key)
            }

            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
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

                dayInput += input
                dayOutput += output

                let cost = CostUsagePricing.codexCostUSD(
                    model: model,
                    inputTokens: input,
                    cachedInputTokens: cached,
                    outputTokens: output)
                breakdown.append(CostUsageDailyReport.ModelBreakdown(modelName: model, costUSD: cost))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            breakdown.sort { lhs, rhs in (rhs.costUSD ?? -1) < (lhs.costUSD ?? -1) }
            let top = Array(breakdown.prefix(3))

            let dayTotal = dayInput + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: top))

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
        sessionId: String? = nil) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            mtimeUnixMs: mtimeUnixMs,
            size: size,
            days: days,
            parsedBytes: parsedBytes,
            lastModel: lastModel,
            lastTotals: lastTotals,
            sessionId: sessionId)
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
