import Foundation

extension CostUsageScanner {
    // MARK: - Muse

    /// Token counts above this are treated as corrupt rather than real usage; they are rejected instead of
    /// flowing into nanodollar conversion or accumulation where they could trap.
    static let museMaxTokenCount = 1_000_000_000_000

    struct MuseUsageRow: Codable, Equatable, Sendable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let input: Int
        let output: Int
        let cacheRead: Int
        let costUSD: Double
    }

    struct MuseParseResult {
        let rows: [MuseUsageRow]
        let parsedBytes: Int64
        /// JSON objects that decoded, whether or not they carried model usage; zero means unreadable telemetry.
        let decodedRecordCount: Int
    }

    /// Muse CLI session logs record every model call twice: a `model_completed` runtime event (with the model name)
    /// and a `goal_usage_attribution` record (without it). Only one of the two may count per file.
    enum MuseRowSource {
        case modelCompleted
        case usageAttribution
        case generic
    }

    /// Collects rows per source and resolves the per-file precedence once parsing finishes.
    struct MuseRowCollector {
        private(set) var completedRows: [MuseUsageRow] = []
        private(set) var attributionRows: [MuseUsageRow] = []
        private(set) var genericRows: [MuseUsageRow] = []

        mutating func append(_ row: MuseUsageRow, source: MuseRowSource) {
            switch source {
            case .modelCompleted: self.completedRows.append(row)
            case .usageAttribution: self.attributionRows.append(row)
            case .generic: self.genericRows.append(row)
            }
        }

        var rows: [MuseUsageRow] {
            if !self.completedRows.isEmpty {
                return self.completedRows + self.genericRows
            }
            return self.attributionRows + self.genericRows
        }
    }

    private final class MuseScanState {
        var cache: CostUsageCache
        var touched: Set<String>
        let range: CostUsageDayRange
        let forceFullScan: Bool
        let isContributor: Bool
        let checkCancellation: CancellationCheck?

        init(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            forceFullScan: Bool,
            isContributor: Bool,
            checkCancellation: CancellationCheck?)
        {
            self.cache = cache
            self.touched = []
            self.range = range
            self.isContributor = isContributor
            self.forceFullScan = forceFullScan
            self.checkCancellation = checkCancellation
        }
    }

    static func loadMuseDaily(
        days: Int = 30,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck? = nil) throws -> CostUsageDailyReport
    {
        let until = now
        let since = Calendar.current.date(byAdding: .day, value: -days, to: until) ?? until
        let range = CostUsageDayRange(since: since, until: until)
        return try self.loadMuseDaily(
            range: range,
            now: now,
            options: options,
            checkCancellation: checkCancellation)
    }

    static func loadMuseDaily(
        range: CostUsageDayRange,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck? = nil) throws -> CostUsageDailyReport
    {
        try checkCancellation?()
        // The pricing tier is part of the cache identity: Standard and Contributor rates never share cached rows.
        let isContributor = options.museIsContributor ?? MuseSettingsReader.readSettings().isContributor
        var cache = CostUsageMuseCacheIO.load(
            cacheRoot: options.cacheRoot,
            isContributor: isContributor,
            calendar: range.calendar)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = self.requestedWindowExpandsCache(range: range, cache: cache)
        let shouldRefresh = options.forceRescan || windowExpanded || (nowMs - cache.lastScanUnixMs) >= refreshMs

        let roots = options.museSessionsRoots ?? MuseSettingsReader.defaultSessionRoots()

        if shouldRefresh {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
            }
            let scanState = MuseScanState(
                cache: cache,
                range: range,
                forceFullScan: options.forceRescan || windowExpanded,
                isContributor: isContributor,
                checkCancellation: checkCancellation)

            for root in roots {
                try self.scanMuseRoot(root: root, state: scanState)
            }
            try checkCancellation?()

            cache = scanState.cache
            let touched = scanState.touched
            cache.roots = nil

            for key in cache.files.keys where !touched.contains(key) {
                cache.files.removeValue(forKey: key)
            }

            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            CostUsageMuseCacheIO.save(
                cache: cache,
                cacheRoot: options.cacheRoot,
                isContributor: isContributor,
                calendar: range.calendar)
        }

        return self.buildMuseReport(from: cache, range: range)
    }

    private static func scanMuseRoot(root: URL, state: MuseScanState) throws {
        try state.checkCancellation?()
        guard FileManager.default.fileExists(atPath: root.path) else { return }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])
        else { return }

        for case let fileURL as URL in enumerator {
            try state.checkCancellation?()
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "json" || ext == "jsonl" else { continue }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)),
                  let size = resourceValues.fileSize,
                  let mtime = resourceValues.contentModificationDate
            else { continue }

            let mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000)
            let path = fileURL.path
            state.touched.insert(path)

            if let cached = state.cache.files[path],
               cached.mtimeUnixMs == mtimeMs,
               cached.size == Int64(size),
               !state.forceFullScan
            {
                continue
            }

            let parsed = try self.parseMuseFileCancellable(
                fileURL: fileURL,
                range: state.range,
                isContributor: state.isContributor,
                checkCancellation: state.checkCancellation)

            let rows = parsed.rows
            let daysMap: [String: [String: [Int]]] = self.packMuseRows(rows)

            state.cache.files[path] = CostUsageFileUsage(
                mtimeUnixMs: mtimeMs,
                size: Int64(size),
                days: daysMap,
                parsedBytes: parsed.parsedBytes)
        }
    }

    private static func packMuseRows(_ rows: [MuseUsageRow]) -> [String: [String: [Int]]] {
        var days: [String: [String: [Int]]] = [:]
        for row in rows {
            // Rows that cannot be represented as nanodollars or that overflow the running totals are dropped
            // rather than allowed to trap; the per-row cap already excludes corrupt counts upstream.
            guard let costNanos = Int(exactly: (row.costUSD * Self.costScale).rounded()) else { continue }
            var models = days[row.dayKey] ?? [:]
            let current = models[row.model] ?? [0, 0, 0, 0]
            guard let packed = Self.checkedSum(current, [row.input, row.output, row.cacheRead, costNanos])
            else { continue }
            models[row.model] = packed
            days[row.dayKey] = models
        }
        return days
    }

    /// Element-wise checked addition; nil when any component would overflow.
    static func checkedSum(_ lhs: [Int], _ rhs: [Int]) -> [Int]? {
        guard lhs.count == rhs.count else { return nil }
        var out: [Int] = []
        out.reserveCapacity(lhs.count)
        for (left, right) in zip(lhs, rhs) {
            let (sum, overflow) = left.addingReportingOverflow(right)
            guard !overflow else { return nil }
            out.append(sum)
        }
        return out
    }

    static func parseMuseFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        isContributor: Bool = false,
        checkCancellation: CancellationCheck? = nil) throws -> MuseParseResult
    {
        try checkCancellation?()
        let ext = fileURL.pathExtension.lowercased()

        if ext == "jsonl" {
            return try self.parseMuseJSONL(
                fileURL: fileURL,
                range: range,
                isContributor: isContributor,
                checkCancellation: checkCancellation)
        } else {
            return try self.parseMuseJSON(
                fileURL: fileURL,
                range: range,
                isContributor: isContributor,
                checkCancellation: checkCancellation)
        }
    }

    private static func parseMuseJSONL(
        fileURL: URL,
        range: CostUsageDayRange,
        isContributor: Bool,
        checkCancellation: CancellationCheck?) throws -> MuseParseResult
    {
        var collector = MuseRowCollector()
        var decodedRecordCount = 0
        let maxLineBytes = 512 * 1024

        let parsedBytes = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: 0,
            maxLineBytes: maxLineBytes,
            prefixBytes: maxLineBytes,
            checkCancellation: checkCancellation,
            onLine: { line in
                guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any] else { return }
                decodedRecordCount += 1
                if let parsed = self.parseMuseObject(
                    obj: obj,
                    range: range,
                    isContributor: isContributor,
                    fallbackSessionId: fileURL.deletingPathExtension().lastPathComponent)
                {
                    collector.append(parsed.row, source: parsed.source)
                }
            })

        return MuseParseResult(rows: collector.rows, parsedBytes: parsedBytes, decodedRecordCount: decodedRecordCount)
    }

    private static func parseMuseJSON(
        fileURL: URL,
        range: CostUsageDayRange,
        isContributor: Bool,
        checkCancellation: CancellationCheck?) throws -> MuseParseResult
    {
        try checkCancellation?()
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return MuseParseResult(rows: [], parsedBytes: 0, decodedRecordCount: 0)
        }

        var collector = MuseRowCollector()
        var decodedRecordCount = 0
        let fallbackId = fileURL.deletingPathExtension().lastPathComponent
        func collect(_ obj: [String: Any]) {
            decodedRecordCount += 1
            if let parsed = self.parseMuseObject(
                obj: obj,
                range: range,
                isContributor: isContributor,
                fallbackSessionId: fallbackId)
            {
                collector.append(parsed.row, source: parsed.source)
            }
        }

        if let array = json as? [[String: Any]] {
            array.forEach(collect)
        } else if let dict = json as? [String: Any] {
            if let messages = dict["messages"] as? [[String: Any]] {
                messages.forEach(collect)
            } else if let events = dict["events"] as? [[String: Any]] {
                events.forEach(collect)
            } else {
                collect(dict)
            }
        }

        return MuseParseResult(
            rows: collector.rows,
            parsedBytes: Int64(data.count),
            decodedRecordCount: decodedRecordCount)
    }

    private static func parseMuseObject(
        obj: [String: Any],
        range: CostUsageDayRange,
        isContributor: Bool,
        fallbackSessionId: String) -> (row: MuseUsageRow, source: MuseRowSource)?
    {
        var source = MuseRowSource.generic
        var dayKey: String?
        if let tsText = (obj["timestamp"] as? String)
            ?? (obj["created_at"] as? String)
            ?? (obj["time"] as? String)
            ?? (obj["date"] as? String)
        {
            dayKey = self.dayKeyFromTimestamp(tsText) ?? self.dayKeyFromParsedISO(tsText)
        } else if let recordedAt = (obj["recorded_at"] as? Double)
            ?? (obj["recorded_at"] as? Int64).map({ Double($0) })
            ?? (obj["recorded_at"] as? Int).map({ Double($0) })
        {
            let seconds = recordedAt > 1e14 ? (recordedAt / 1_000_000.0) :
                (recordedAt > 1e11 ? (recordedAt / 1000.0) : recordedAt)
            dayKey = CostUsageDayRange.dayKey(from: Date(timeIntervalSince1970: seconds))
        }

        guard let dayKey,
              CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
        else {
            return nil
        }

        var usageDict: [String: Any]? = (obj["usage"] as? [String: Any])
            ?? ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
        var modelCandidate: String? = (obj["model"] as? String)
            ?? ((obj["message"] as? [String: Any])?["model"] as? String)

        if let payload = obj["payload"] as? [String: Any] {
            if modelCandidate == nil {
                modelCandidate = (payload["model_id"] as? String) ?? (payload["model"] as? String)
            }
            let event = payload["event"] as? [String: Any]
            if usageDict == nil {
                if let event,
                   event["kind"] as? String == "model_completed",
                   let usage = event["usage"] as? [String: Any]
                {
                    source = .modelCompleted
                    usageDict = usage
                    if let model = event["model"] as? String { modelCandidate = model }
                } else if let event,
                          let record = event["record"] as? [String: Any],
                          let quantity = record["quantity"] as? [String: Any]
                {
                    source = .usageAttribution
                    usageDict = quantity
                } else if let record = payload["record"] as? [String: Any],
                          let quantity = record["quantity"] as? [String: Any]
                {
                    usageDict = quantity
                } else if let quantity = payload["quantity"] as? [String: Any] {
                    usageDict = quantity
                }
            }
        }

        let modelRaw = modelCandidate ?? "muse-spark-1.3"
        let model = CostUsagePricing.normalizeMuseModel(modelRaw)
        let usage = usageDict ?? obj

        guard let input = self.museTokenCount(usage["input_tokens"] ?? usage["prompt_tokens"]),
              let output = self.museTokenCount(usage["output_tokens"] ?? usage["completion_tokens"]),
              let cacheRead = self.museTokenCount(
                  usage["cache_read_input_tokens"]
                      ?? usage["cache_read_tokens"]
                      ?? usage["cached_tokens"]
                      ?? usage["cached_input_tokens"])
        else { return nil }

        guard input > 0 || output > 0 || cacheRead > 0 else { return nil }

        let cost = CostUsagePricing.museCostUSD(
            model: model,
            inputTokens: input,
            cacheReadInputTokens: cacheRead,
            outputTokens: output,
            isContributor: isContributor) ?? 0.0

        let sessionId = (obj["session_id"] as? String)
            ?? (obj["sessionId"] as? String)
            ?? fallbackSessionId

        let row = MuseUsageRow(
            dayKey: dayKey,
            model: model,
            sessionId: sessionId,
            input: input,
            output: output,
            cacheRead: cacheRead,
            costUSD: cost)
        return (row, source)
    }

    /// Missing counts are zero; present counts must be non-negative integers within the sanity cap.
    /// Anything else marks the record as corrupt and rejects it.
    private static func museTokenCount(_ raw: Any?) -> Int? {
        guard let raw else { return 0 }
        let value: Int
        if let int = raw as? Int {
            value = int
        } else if let double = raw as? Double, let exact = Int(exactly: double) {
            value = exact
        } else {
            return nil
        }
        guard value >= 0, value <= Self.museMaxTokenCount else { return nil }
        return value
    }

    private static func buildMuseReport(from cache: CostUsageCache, range: CostUsageDayRange) -> CostUsageDailyReport {
        var dayMap: [String: [String: (input: Int, output: Int, cacheRead: Int, cost: Double)]] = [:]

        for (_, file) in cache.files {
            for (dayKey, models) in file.days {
                guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
                else {
                    continue
                }
                var currentModels = dayMap[dayKey] ?? [:]
                for (model, packed) in models {
                    var m = currentModels[model] ?? (0, 0, 0, 0.0)
                    guard let summed = Self.checkedSum(
                        [m.input, m.output, m.cacheRead],
                        [packed[safe: 0] ?? 0, packed[safe: 1] ?? 0, packed[safe: 2] ?? 0])
                    else { continue }
                    m.input = summed[0]
                    m.output = summed[1]
                    m.cacheRead = summed[2]
                    m.cost += Double(packed[safe: 3] ?? 0) / Self.costScale
                    currentModels[model] = m
                }
                dayMap[dayKey] = currentModels
            }
        }

        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalTokens = 0
        var totalCost: Double = 0

        let sortedDays = dayMap.keys.sorted()
        for dayKey in sortedDays {
            guard let models = dayMap[dayKey] else { continue }
            var dayInput = 0
            var dayOutput = 0
            var dayCacheRead = 0
            var dayCost: Double = 0
            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []

            for (model, stats) in models.sorted(by: { $0.key < $1.key }) {
                guard let summed = Self.checkedSum(
                    [dayInput, dayOutput, dayCacheRead, stats.input],
                    [stats.input, stats.output, stats.cacheRead, stats.output])
                else { continue }
                let modelTotal = summed[3]
                dayInput = summed[0]
                dayOutput = summed[1]
                dayCacheRead = summed[2]
                dayCost += stats.cost
                breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: stats.cost,
                    totalTokens: modelTotal))
            }

            guard let dayTotal = Self.checkedSum([dayInput], [dayOutput])?.first,
                  let summedTotals = Self.checkedSum(
                      [totalInput, totalOutput, totalCacheRead, totalTokens],
                      [dayInput, dayOutput, dayCacheRead, dayTotal])
            else { continue }
            totalInput = summedTotals[0]
            totalOutput = summedTotals[1]
            totalCacheRead = summedTotals[2]
            totalTokens = summedTotals[3]
            totalCost += dayCost

            entries.append(CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCacheRead,
                totalTokens: dayTotal,
                costUSD: dayCost,
                modelsUsed: breakdowns.map(\.modelName),
                modelBreakdowns: breakdowns))
        }

        let summary = CostUsageDailyReport.Summary(
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            totalTokens: totalTokens,
            totalCostUSD: totalCost)

        return CostUsageDailyReport(data: entries, summary: summary)
    }
}

/// Muse keeps a small JSON session cache beside the Claude/Vertex artifacts. Codex deliberately has no route
/// through this JSON I/O boundary; its only persistence authority is `CostUsageStore`.
enum CostUsageMuseCacheIO {
    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    /// Standard and Contributor pricing produce different cached costs, so each tier owns its own artifact.
    static func cacheFileURL(cacheRoot: URL? = nil, isContributor: Bool = false) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        let tier = isContributor ? "contributor" : "standard"
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("muse-v1-\(tier).json", isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil, isContributor: Bool = false, calendar: Calendar? = nil) -> CostUsageCache {
        let url = self.cacheFileURL(cacheRoot: cacheRoot, isContributor: isContributor)
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CostUsageCache.self, from: data),
              cache.version == 1
        else { return CostUsageCache() }
        if let calendar, cache.timeZoneIdentifier != calendar.timeZone.identifier {
            return CostUsageCache()
        }
        return cache
    }

    static func save(
        cache: CostUsageCache,
        cacheRoot: URL? = nil,
        isContributor: Bool = false,
        calendar: Calendar = .current)
    {
        let url = self.cacheFileURL(cacheRoot: cacheRoot, isContributor: isContributor)
        var cache = cache
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".cache-muse-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL)
            if rename(temporaryURL.path, url.path) != 0 {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}
