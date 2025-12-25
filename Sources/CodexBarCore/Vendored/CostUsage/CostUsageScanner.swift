import Foundation

enum CostUsageScanner {
    struct Options: Sendable {
        var codexSessionsRoot: URL?
        var claudeProjectsRoots: [URL]?
        var cacheRoot: URL?
        var refreshMinIntervalSeconds: TimeInterval = 60

        init(
            codexSessionsRoot: URL? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil)
        {
            self.codexSessionsRoot = codexSessionsRoot
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
        }
    }

    struct CodexParseResult: Sendable {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
        let lastModel: String?
        let lastTotals: CostUsageCodexTotals?
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
        options: Options = Options()) -> CCUsageDailyReport
    {
        let range = CostUsageDayRange(since: since, until: until)

        switch provider {
        case .codex:
            return self.loadCodexDaily(range: range, now: now, options: options)
        case .claude:
            return self.loadClaudeDaily(range: range, now: now, options: options)
        case .gemini:
            return CCUsageDailyReport(data: [], summary: nil)
        case .antigravity:
            return CCUsageDailyReport(data: [], summary: nil)
        case .cursor:
            return CCUsageDailyReport(data: [], summary: nil)
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

    private static func listCodexSessionFiles(root: URL, scanSinceKey: String, scanUntilKey: String) -> [URL] {
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

    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil) -> CodexParseResult
    {
        var currentModel = initialModel
        var previousTotals = initialTotals

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
                else { return }

                if line.bytes.containsAscii(#""type":"event_msg""#), !line.bytes.containsAscii(#""token_count""#) {
                    return
                }

                guard
                    let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                    let type = obj["type"] as? String
                else { return }

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
            lastTotals: previousTotals)
    }

    private static func loadCodexDaily(range: CostUsageDayRange, now: Date, options: Options) -> CCUsageDailyReport {
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let shouldRefresh = refreshMs == 0 || cache.lastScanUnixMs == 0 || nowMs - cache.lastScanUnixMs > refreshMs

        let root = self.defaultCodexSessionsRoot(options: options)
        let files = Self.listCodexSessionFiles(
            root: root,
            scanSinceKey: range.scanSinceKey,
            scanUntilKey: range.scanUntilKey)
        let filePathsInScan = Set(files.map(\.path))

        if shouldRefresh {
            for fileURL in files {
                let path = fileURL.path
                let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mtimeMs = Int64(mtime * 1000)

                if let cached = cache.files[path],
                   cached.mtimeUnixMs == mtimeMs,
                   cached.size == size
                {
                    continue
                }

                if let cached = cache.files[path] {
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
                            lastTotals: delta.lastTotals)
                        continue
                    }

                    Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
                }

                let parsed = Self.parseCodexFile(fileURL: fileURL, range: range)
                let usage = Self.makeFileUsage(
                    mtimeUnixMs: mtimeMs,
                    size: size,
                    days: parsed.days,
                    parsedBytes: parsed.parsedBytes,
                    lastModel: parsed.lastModel,
                    lastTotals: parsed.lastTotals)
                cache.files[path] = usage
                Self.applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
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
        range: CostUsageDayRange) -> CCUsageDailyReport
    {
        var entries: [CCUsageDailyReport.Entry] = []
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

            var breakdown: [CCUsageDailyReport.ModelBreakdown] = []
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
                breakdown.append(CCUsageDailyReport.ModelBreakdown(modelName: model, costUSD: cost))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            breakdown.sort { lhs, rhs in (rhs.costUSD ?? -1) < (lhs.costUSD ?? -1) }
            let top = Array(breakdown.prefix(3))

            let dayTotal = dayInput + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CCUsageDailyReport.Entry(
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

        let summary: CCUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CCUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                totalTokens: totalTokens,
                totalCostUSD: costSeen ? totalCost : nil)

        return CCUsageDailyReport(data: entries, summary: summary)
    }

    // MARK: - Claude

    private static func defaultClaudeProjectsRoots(options: Options) -> [URL] {
        if let override = options.claudeProjectsRoots { return override }

        var roots: [URL] = []

        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !env.isEmpty
        {
            for part in env.split(separator: ",") {
                let raw = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let url = URL(fileURLWithPath: raw)
                if url.lastPathComponent == "projects" {
                    roots.append(url)
                } else {
                    roots.append(url.appendingPathComponent("projects", isDirectory: true))
                }
            }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
            roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))
        }

        return roots
    }

    static func parseClaudeFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0) -> ClaudeParseResult
    {
        var days: [String: [String: [Int]]] = [:]

        struct ClaudeTokens: Sendable {
            let input: Int
            let cacheRead: Int
            let cacheCreate: Int
            let output: Int
        }

        func add(dayKey: String, model: String, tokens: ClaudeTokens) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeClaudeModel(model)
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + tokens.input
            packed[1] = (packed[safe: 1] ?? 0) + tokens.cacheRead
            packed[2] = (packed[safe: 2] ?? 0) + tokens.cacheCreate
            packed[3] = (packed[safe: 3] ?? 0) + tokens.output
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        let maxLineBytes = 256 * 1024
        let prefixBytes = 64 * 1024

        let parsedBytes = (try? CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: startOffset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            onLine: { line in
                guard !line.bytes.isEmpty else { return }
                guard !line.wasTruncated else { return }
                guard line.bytes.containsAscii(#""type":"assistant""#) else { return }
                guard line.bytes.containsAscii(#""usage""#) else { return }

                guard
                    let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                    let type = obj["type"] as? String,
                    type == "assistant"
                else { return }

                guard let tsText = obj["timestamp"] as? String else { return }
                guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) else { return }

                guard let message = obj["message"] as? [String: Any] else { return }
                guard let model = message["model"] as? String else { return }
                guard let usage = message["usage"] as? [String: Any] else { return }

                func toInt(_ v: Any?) -> Int {
                    if let n = v as? NSNumber { return n.intValue }
                    return 0
                }

                let input = max(0, toInt(usage["input_tokens"]))
                let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
                let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
                let output = max(0, toInt(usage["output_tokens"]))
                if input == 0, cacheCreate == 0, cacheRead == 0, output == 0 { return }

                let tokens = ClaudeTokens(input: input, cacheRead: cacheRead, cacheCreate: cacheCreate, output: output)
                add(dayKey: dayKey, model: model, tokens: tokens)
            })) ?? startOffset

        return ClaudeParseResult(days: days, parsedBytes: parsedBytes)
    }

    private static func claudeRootCandidates(for rootPath: String) -> [String] {
        if rootPath.hasPrefix("/var/") {
            return ["/private" + rootPath, rootPath]
        }
        if rootPath.hasPrefix("/private/var/") {
            let trimmed = String(rootPath.dropFirst("/private".count))
            return [rootPath, trimmed]
        }
        return [rootPath]
    }

    private final class ClaudeScanState {
        var cache: CostUsageCache
        var rootCache: [String: Int64]
        var touched: Set<String>

        init(cache: CostUsageCache) {
            self.cache = cache
            self.rootCache = cache.roots ?? [:]
            self.touched = []
        }
    }

    private static func processClaudeFile(
        url: URL,
        size: Int64,
        mtimeMs: Int64,
        range: CostUsageDayRange,
        state: ClaudeScanState)
    {
        let path = url.path
        state.touched.insert(path)

        if let cached = state.cache.files[path],
           cached.mtimeUnixMs == mtimeMs,
           cached.size == size
        {
            return
        }

        if let cached = state.cache.files[path] {
            let startOffset = cached.parsedBytes ?? cached.size
            let canIncremental = size > cached.size && startOffset > 0 && startOffset <= size
            if canIncremental {
                let delta = Self.parseClaudeFile(
                    fileURL: url,
                    range: range,
                    startOffset: startOffset)
                if !delta.days.isEmpty {
                    Self.applyFileDays(cache: &state.cache, fileDays: delta.days, sign: 1)
                }

                var mergedDays = cached.days
                Self.mergeFileDays(existing: &mergedDays, delta: delta.days)
                state.cache.files[path] = Self.makeFileUsage(
                    mtimeUnixMs: mtimeMs,
                    size: size,
                    days: mergedDays,
                    parsedBytes: delta.parsedBytes)
                return
            }

            Self.applyFileDays(cache: &state.cache, fileDays: cached.days, sign: -1)
        }

        let parsed = Self.parseClaudeFile(fileURL: url, range: range)
        let usage = Self.makeFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            days: parsed.days,
            parsedBytes: parsed.parsedBytes)
        state.cache.files[path] = usage
        Self.applyFileDays(cache: &state.cache, fileDays: usage.days, sign: 1)
    }

    private static func scanClaudeRoot(
        root: URL,
        range: CostUsageDayRange,
        state: ClaudeScanState)
    {
        let rootPath = root.path
        let rootCandidates = Self.claudeRootCandidates(for: rootPath)
        let prefixes = Set(rootCandidates).map { path in
            path.hasSuffix("/") ? path : "\(path)/"
        }
        let rootExists = rootCandidates.contains { FileManager.default.fileExists(atPath: $0) }
        let canonicalRootPath = rootCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) ?? rootPath

        guard rootExists else {
            let stale = state.cache.files.keys.filter { path in
                prefixes.contains(where: { path.hasPrefix($0) })
            }
            for path in stale {
                if let old = state.cache.files[path] {
                    Self.applyFileDays(cache: &state.cache, fileDays: old.days, sign: -1)
                }
                state.cache.files.removeValue(forKey: path)
            }
            for candidate in rootCandidates {
                state.rootCache.removeValue(forKey: candidate)
            }
            return
        }

        let rootAttrs = (try? FileManager.default.attributesOfItem(atPath: canonicalRootPath)) ?? [:]
        let rootMtime = (rootAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let rootMtimeMs = Int64(rootMtime * 1000)
        let cachedRootMtime = rootCandidates.compactMap { state.rootCache[$0] }.first
        let canSkipEnumeration = cachedRootMtime == rootMtimeMs && rootMtimeMs > 0

        if canSkipEnumeration {
            let cachedPaths = state.cache.files.keys.filter { path in
                prefixes.contains(where: { path.hasPrefix($0) })
            }
            for path in cachedPaths {
                guard FileManager.default.fileExists(atPath: path) else {
                    if let old = state.cache.files[path] {
                        Self.applyFileDays(cache: &state.cache, fileDays: old.days, sign: -1)
                    }
                    state.cache.files.removeValue(forKey: path)
                    continue
                }
                let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 0 { continue }
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let mtimeMs = Int64(mtime * 1000)
                Self.processClaudeFile(
                    url: URL(fileURLWithPath: path),
                    size: size,
                    mtimeMs: mtimeMs,
                    range: range,
                    state: state)
            }
            return
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            if size <= 0 { continue }

            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let mtimeMs = Int64(mtime * 1000)
            Self.processClaudeFile(
                url: url,
                size: size,
                mtimeMs: mtimeMs,
                range: range,
                state: state)
        }

        if rootMtimeMs > 0 {
            state.rootCache[canonicalRootPath] = rootMtimeMs
            for candidate in rootCandidates where candidate != canonicalRootPath {
                state.rootCache.removeValue(forKey: candidate)
            }
        }
    }

    private static func loadClaudeDaily(range: CostUsageDayRange, now: Date, options: Options) -> CCUsageDailyReport {
        var cache = CostUsageCacheIO.load(provider: .claude, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let shouldRefresh = refreshMs == 0 || cache.lastScanUnixMs == 0 || nowMs - cache.lastScanUnixMs > refreshMs

        let roots = self.defaultClaudeProjectsRoots(options: options)

        var touched: Set<String> = []

        if shouldRefresh {
            let scanState = ClaudeScanState(cache: cache)

            for root in roots {
                Self.scanClaudeRoot(
                    root: root,
                    range: range,
                    state: scanState)
            }

            cache = scanState.cache
            touched = scanState.touched
            cache.roots = scanState.rootCache.isEmpty ? nil : scanState.rootCache

            for key in cache.files.keys where !touched.contains(key) {
                if let old = cache.files[key] {
                    Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
                }
                cache.files.removeValue(forKey: key)
            }

            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.lastScanUnixMs = nowMs
            CostUsageCacheIO.save(provider: .claude, cache: cache, cacheRoot: options.cacheRoot)
        }

        return Self.buildClaudeReportFromCache(cache: cache, range: range)
    }

    private static func buildClaudeReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> CCUsageDailyReport
    {
        var entries: [CCUsageDailyReport.Entry] = []
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

            var breakdown: [CCUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for model in modelNames {
                let packed = models[model] ?? [0, 0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cacheRead = packed[safe: 1] ?? 0
                let cacheCreate = packed[safe: 2] ?? 0
                let output = packed[safe: 3] ?? 0

                let inputTotal = input + cacheRead + cacheCreate
                dayInput += inputTotal
                dayOutput += output

                let cost = CostUsagePricing.claudeCostUSD(
                    model: model,
                    inputTokens: input,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheCreate,
                    outputTokens: output)
                breakdown.append(CCUsageDailyReport.ModelBreakdown(modelName: model, costUSD: cost))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            breakdown.sort { lhs, rhs in (rhs.costUSD ?? -1) < (lhs.costUSD ?? -1) }
            let top = Array(breakdown.prefix(3))

            let dayTotal = dayInput + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CCUsageDailyReport.Entry(
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

        let summary: CCUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CCUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                totalTokens: totalTokens,
                totalCostUSD: costSeen ? totalCost : nil)

        return CCUsageDailyReport(data: entries, summary: summary)
    }

    // MARK: - Shared cache mutations

    private static func makeFileUsage(
        mtimeUnixMs: Int64,
        size: Int64,
        days: [String: [String: [Int]]],
        parsedBytes: Int64?,
        lastModel: String? = nil,
        lastTotals: CostUsageCodexTotals? = nil) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            mtimeUnixMs: mtimeUnixMs,
            size: size,
            days: days,
            parsedBytes: parsedBytes,
            lastModel: lastModel,
            lastTotals: lastTotals)
    }

    private static func mergeFileDays(
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

    private static func applyFileDays(cache: inout CostUsageCache, fileDays: [String: [String: [Int]]], sign: Int) {
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

    private static func pruneDays(cache: inout CostUsageCache, sinceKey: String, untilKey: String) {
        for key in cache.days.keys where !CostUsageDayRange.isInRange(dayKey: key, since: sinceKey, until: untilKey) {
            cache.days.removeValue(forKey: key)
        }
    }

    private static func addPacked(a: [Int], b: [Int], sign: Int) -> [Int] {
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
    fileprivate func containsAscii(_ needle: String) -> Bool {
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
