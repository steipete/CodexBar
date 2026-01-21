import Foundation

extension CostUsageScanner {
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
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0) -> ClaudeParseResult
    {
        var days: [String: [String: [Int]]] = [:]
        // Track seen message+request IDs to deduplicate streaming chunks within a JSONL file.
        // Claude emits multiple lines per message with cumulative usage, so we only count once.
        var seenKeys: Set<String> = []

        struct ClaudeTokens: Sendable {
            let input: Int
            let cacheRead: Int
            let cacheCreate: Int
            let output: Int
            let costNanos: Int
        }

        func add(dayKey: String, model: String, tokens: ClaudeTokens) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeClaudeModel(model)
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + tokens.input
            packed[1] = (packed[safe: 1] ?? 0) + tokens.cacheRead
            packed[2] = (packed[safe: 2] ?? 0) + tokens.cacheCreate
            packed[3] = (packed[safe: 3] ?? 0) + tokens.output
            packed[4] = (packed[safe: 4] ?? 0) + tokens.costNanos
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        let maxLineBytes = 512 * 1024
        // Keep the full line so usage at the tail isn't dropped on large tool outputs.
        let prefixBytes = maxLineBytes
        let costScale = 1_000_000_000.0

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
                guard Self.matchesClaudeProviderFilter(obj: obj, filter: providerFilter) else { return }

                guard let tsText = obj["timestamp"] as? String else { return }
                guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) else { return }

                guard let message = obj["message"] as? [String: Any] else { return }
                guard let model = message["model"] as? String else { return }
                guard let usage = message["usage"] as? [String: Any] else { return }

                // Deduplicate by message.id + requestId (streaming chunks have same usage).
                let messageId = message["id"] as? String
                let requestId = obj["requestId"] as? String
                if let messageId, let requestId {
                    let key = "\(messageId):\(requestId)"
                    if seenKeys.contains(key) { return }
                    seenKeys.insert(key)
                } else {
                    // Older logs omit IDs; treat each line as distinct to avoid dropping usage.
                }

                func toInt(_ v: Any?) -> Int {
                    if let n = v as? NSNumber { return n.intValue }
                    return 0
                }

                let input = max(0, toInt(usage["input_tokens"]))
                let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
                let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
                let output = max(0, toInt(usage["output_tokens"]))
                if input == 0, cacheCreate == 0, cacheRead == 0, output == 0 { return }

                let cost = CostUsagePricing.claudeCostUSD(
                    model: model,
                    inputTokens: input,
                    cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheCreate,
                    outputTokens: output)
                let costNanos = cost.map { Int(($0 * costScale).rounded()) } ?? 0
                let tokens = ClaudeTokens(
                    input: input,
                    cacheRead: cacheRead,
                    cacheCreate: cacheCreate,
                    output: output,
                    costNanos: costNanos)
                add(dayKey: dayKey, model: model, tokens: tokens)
            })) ?? startOffset

        return ClaudeParseResult(days: days, parsedBytes: parsedBytes)
    }

    private static let vertexProviderKeys: Set<String> = [
        "provider",
        "platform",
        "backend",
        "api_provider",
        "apiprovider",
        "api_type",
        "apitype",
        "source",
        "vendor",
        "client",
    ]

    private static func matchesClaudeProviderFilter(
        obj: [String: Any],
        filter: ClaudeLogProviderFilter) -> Bool
    {
        switch filter {
        case .all:
            true
        case .vertexAIOnly:
            self.isVertexAIUsageEntry(obj: obj)
        case .excludeVertexAI:
            !self.isVertexAIUsageEntry(obj: obj)
        }
    }

    private static func isVertexAIUsageEntry(obj: [String: Any]) -> Bool {
        // Primary detection: Vertex AI message IDs and request IDs have "vrtx" prefix
        // e.g., "msg_vrtx_0154LUXjFVzQGUca3yK2RUeo", "req_vrtx_011CWjK86SWeFuXqZKUtgB1H"
        if let message = obj["message"] as? [String: Any],
           let messageId = message["id"] as? String,
           messageId.contains("_vrtx_")
        {
            return true
        }
        if let requestId = obj["requestId"] as? String,
           requestId.contains("_vrtx_")
        {
            return true
        }

        // Secondary detection: model name with @ version separator (Vertex AI format)
        // e.g., "claude-opus-4-5@20251101" vs "claude-opus-4-5-20251101"
        if let message = obj["message"] as? [String: Any],
           let model = message["model"] as? String,
           Self.modelNameLooksVertex(model)
        {
            return true
        }

        // Fallback: check for explicit Vertex AI metadata fields
        var candidates: [[String: Any]] = [obj]
        if let metadata = obj["metadata"] as? [String: Any] { candidates.append(metadata) }
        if let request = obj["request"] as? [String: Any] { candidates.append(request) }
        if let context = obj["context"] as? [String: Any] { candidates.append(context) }
        if let client = obj["client"] as? [String: Any] { candidates.append(client) }
        if let message = obj["message"] as? [String: Any] {
            if let metadata = message["metadata"] as? [String: Any] { candidates.append(metadata) }
            if let request = message["request"] as? [String: Any] { candidates.append(request) }
        }

        return candidates.contains { Self.containsVertexAIMetadata(in: $0) }
    }

    /// Detects Vertex AI model names by format.
    /// Vertex AI uses @ for version separator: claude-opus-4-5@20251101
    /// Anthropic API uses -: claude-opus-4-5-20251101
    private static func modelNameLooksVertex(_ model: String) -> Bool {
        // Vertex AI model format: claude-{variant}@{version}
        // Examples: claude-opus-4-5@20251101, claude-sonnet-4-5@20250514
        guard model.hasPrefix("claude-") else { return false }
        return model.contains("@")
    }

    private static func containsVertexAIMetadata(in dict: [String: Any]) -> Bool {
        for (key, value) in dict {
            let lowerKey = key.lowercased()
            if lowerKey.contains("vertex") || lowerKey.contains("gcp") {
                return true
            }
            if Self.vertexProviderKeys.contains(lowerKey),
               let text = value as? String,
               Self.stringLooksVertex(text)
            {
                return true
            }
            if let nested = value as? [String: Any] {
                if Self.containsVertexAIMetadata(in: nested) { return true }
            } else if let array = value as? [Any] {
                if Self.containsVertexAIMetadata(in: array) { return true }
            }
        }

        return false
    }

    private static func containsVertexAIMetadata(in array: [Any]) -> Bool {
        for entry in array {
            if let dict = entry as? [String: Any] {
                if self.containsVertexAIMetadata(in: dict) { return true }
            }
        }

        return false
    }

    private static func stringLooksVertex(_ value: String) -> Bool {
        value.lowercased().contains("vertex")
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
        let range: CostUsageDayRange
        let providerFilter: ClaudeLogProviderFilter

        init(cache: CostUsageCache, range: CostUsageDayRange, providerFilter: ClaudeLogProviderFilter) {
            self.cache = cache
            self.rootCache = cache.roots ?? [:]
            self.touched = []
            self.range = range
            self.providerFilter = providerFilter
        }
    }

    private static func processClaudeFile(
        url: URL,
        size: Int64,
        mtimeMs: Int64,
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
                    range: state.range,
                    providerFilter: state.providerFilter,
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

        let parsed = Self.parseClaudeFile(
            fileURL: url,
            range: state.range,
            providerFilter: state.providerFilter)
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
                state: state)
        }

        if rootMtimeMs > 0 {
            state.rootCache[canonicalRootPath] = rootMtimeMs
            for candidate in rootCandidates where candidate != canonicalRootPath {
                state.rootCache.removeValue(forKey: candidate)
            }
        }
    }

    static func loadClaudeDaily(
        provider: UsageProvider,
        range: CostUsageDayRange,
        now: Date,
        options: Options) -> CostUsageDailyReport
    {
        var cache = CostUsageCacheIO.load(provider: provider, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let shouldRefresh = refreshMs == 0 || cache.lastScanUnixMs == 0 || nowMs - cache.lastScanUnixMs > refreshMs

        let roots = self.defaultClaudeProjectsRoots(options: options)
        let providerFilter = options.claudeLogProviderFilter

        var touched: Set<String> = []

        if shouldRefresh {
            if options.forceRescan {
                cache = CostUsageCache()
            }
            let scanState = ClaudeScanState(cache: cache, range: range, providerFilter: providerFilter)

            for root in roots {
                Self.scanClaudeRoot(
                    root: root,
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
            CostUsageCacheIO.save(provider: provider, cache: cache, cacheRoot: options.cacheRoot)
        }

        return Self.buildClaudeReportFromCache(cache: cache, range: range)
    }

    private static func buildClaudeReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> CostUsageDailyReport
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreate = 0
        var totalTokens = 0
        var totalCost: Double = 0
        var costSeen = false
        let costScale = 1_000_000_000.0

        let dayKeys = cache.days.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        for day in dayKeys {
            guard let models = cache.days[day] else { continue }
            let modelNames = models.keys.sorted()

            var dayInput = 0
            var dayOutput = 0
            var dayCacheRead = 0
            var dayCacheCreate = 0

            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for model in modelNames {
                let packed = models[model] ?? [0, 0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cacheRead = packed[safe: 1] ?? 0
                let cacheCreate = packed[safe: 2] ?? 0
                let output = packed[safe: 3] ?? 0
                let cachedCost = packed[safe: 4] ?? 0

                // Cache tokens are tracked separately; totalTokens includes input + cache.
                dayInput += input
                dayCacheRead += cacheRead
                dayCacheCreate += cacheCreate
                dayOutput += output

                let cost = cachedCost > 0
                    ? Double(cachedCost) / costScale
                    : CostUsagePricing.claudeCostUSD(
                        model: model,
                        inputTokens: input,
                        cacheReadInputTokens: cacheRead,
                        cacheCreationInputTokens: cacheCreate,
                        outputTokens: output)
                breakdown.append(CostUsageDailyReport.ModelBreakdown(modelName: model, costUSD: cost))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            breakdown.sort { lhs, rhs in (rhs.costUSD ?? -1) < (lhs.costUSD ?? -1) }
            let top = Array(breakdown.prefix(3))

            let dayTotal = dayInput + dayCacheRead + dayCacheCreate + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCacheRead,
                cacheCreationTokens: dayCacheCreate,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: top))

            totalInput += dayInput
            totalOutput += dayOutput
            totalCacheRead += dayCacheRead
            totalCacheCreate += dayCacheCreate
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
                cacheReadTokens: totalCacheRead,
                cacheCreationTokens: totalCacheCreate,
                totalTokens: totalTokens,
                totalCostUSD: costSeen ? totalCost : nil)

        return CostUsageDailyReport(data: entries, summary: summary)
    }
}
