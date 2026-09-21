import Foundation

extension CostUsageScanner {
    static func loadDailyReportCancellable(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        reportContext: CostUsageReportContext?,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        // Provider-specific by design: Claude/Vertex retain window-specific rows in generated JSON caches.
        guard let reportContext, provider == .claude || provider == .vertexai else {
            return try self.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        }
        try checkCancellation?()
        var filtered = options
        if provider == .vertexai, filtered.claudeLogProviderFilter == .all {
            filtered.claudeLogProviderFilter = .vertexAIOnly
        }
        return try self.loadClaudeDaily(
            provider: provider,
            range: CostUsageDayRange(since: since, until: until, calendar: options.calendar),
            now: now,
            options: filtered,
            reportContext: reportContext,
            checkCancellation: checkCancellation)
    }

    // MARK: - Claude

    private struct ClaudeTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int
        let output: Int
        let costNanos: Int
        let costPriced: Bool
    }

    private struct ClaudeDayModelKey: Hashable {
        let day: String
        let model: String
    }

    private enum ClaudeRowKey: Hashable, Comparable {
        case request(messageId: String, requestId: String)
        case session(sessionId: String, messageId: String)

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.request(lhsMessage, lhsRequest), .request(rhsMessage, rhsRequest)):
                (lhsMessage, lhsRequest) < (rhsMessage, rhsRequest)
            case let (.session(lhsSession, lhsMessage), .session(rhsSession, rhsMessage)):
                (lhsSession, lhsMessage) < (rhsSession, rhsMessage)
            case (.request, .session):
                true
            case (.session, .request):
                false
            }
        }
    }

    private struct ClaudeReportAggregate {
        var total: Double = 0
        var sampleCount: Int = 0
        var unresolved = false
        var incompleteRequestCount = 0
        var input = CostUsageDailyReport.OptionalCountAccumulator(0)
        var output = CostUsageDailyReport.OptionalCountAccumulator(0)
        var cacheRead = CostUsageDailyReport.OptionalCountAccumulator(0)
        var cacheCreate = CostUsageDailyReport.OptionalCountAccumulator(0)

        var totalTokens: Int? {
            var total = self.input
            total.merge(self.output)
            total.merge(self.cacheRead)
            total.merge(self.cacheCreate)
            return total.value
        }

        init() {}

        init(packed: [Int]) {
            self.input.add(packed[safe: 0])
            self.cacheRead.add(packed[safe: 1])
            self.cacheCreate.add(packed[safe: 2])
            self.output.add(packed[safe: 3])
            self.sampleCount = max(0, packed[safe: 5] ?? 0)
        }
    }

    static func defaultClaudeProjectsRoots(
        options: Options,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil) -> [URL]
    {
        if let override = options.claudeProjectsRoots {
            return override
        }

        var roots: [URL] = []

        if let configuredRoot = environment[ClaudeConfigPaths.configDirectoryEnvironmentKey],
           !configuredRoot.isEmpty
        {
            let root = ClaudeConfigPaths.configRoot(
                environment: environment,
                workingDirectory: workingDirectory)
            roots.append(root.appendingPathComponent("projects", isDirectory: true))
        } else {
            var pathEnvironment = environment
            if pathEnvironment["HOME"]?.isEmpty ?? true {
                pathEnvironment["HOME"] = homeDirectory.path
            }
            let ownerHome = ClaudeConfigPaths.homeDirectory(
                environment: pathEnvironment,
                workingDirectory: workingDirectory)
            let configRoot = ClaudeConfigPaths.configRoot(
                environment: pathEnvironment,
                workingDirectory: workingDirectory)
            roots.append(ownerHome.appendingPathComponent(".config/claude/projects", isDirectory: true))
            roots.append(configRoot.appendingPathComponent("projects", isDirectory: true))
            roots.append(contentsOf: ClaudeDesktopProjectsLocator.roots(
                homeDirectory: ownerHome,
                fileManager: fileManager))
        }

        return self.deduplicatedClaudeProjectRoots(roots)
    }

    private static func deduplicatedClaudeProjectRoots(_ roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for root in roots {
            let standardized = root.standardizedFileURL
            let path = standardized.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(standardized)
        }
        return out
    }

    static func parseClaudeFile(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> ClaudeParseResult
    {
        let pricingResolver = modelsDevCatalog.map { CostUsagePricing.ClaudeResolver(catalog: $0) }
            ?? CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: modelsDevCacheRoot)
        return (
            try? self.parseClaudeFileCancellable(
                fileURL: fileURL,
                range: range,
                providerFilter: providerFilter,
                startOffset: startOffset,
                pricingResolver: pricingResolver,
                checkCancellation: nil)) ?? ClaudeParseResult(rows: [], parsedBytes: startOffset)
    }

    static func parseClaudeFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        pricingResolver: CostUsagePricing.ClaudeResolver,
        checkCancellation: CancellationCheck? = nil) throws -> ClaudeParseResult
    {
        func toInt(_ v: Any?) -> Int {
            if let n = v as? NSNumber {
                return n.intValue
            }
            return 0
        }

        func toBool(_ value: Any?) -> Bool {
            if let bool = value as? Bool {
                return bool
            }
            if let number = value as? NSNumber {
                return number.boolValue
            }
            return false
        }

        let pathRole = Self.claudePathRole(fileURL: fileURL)
        var keyedRows: [ClaudeRowKey: ClaudeUsageRow] = [:]
        var unkeyedRows: [ClaudeUsageRow] = []

        let maxLineBytes = 512 * 1024
        // Keep the full line so usage at the tail isn't dropped on large tool outputs.
        let prefixBytes = maxLineBytes
        let costScale = 1_000_000_000.0

        let parsedBytes: Int64
        do {
            parsedBytes = try CostUsageJsonl.scan(
                fileURL: fileURL,
                offset: startOffset,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                checkCancellation: checkCancellation,
                onLine: { line in
                    guard !line.bytes.isEmpty else { return }
                    guard !line.wasTruncated else { return }
                    guard line.bytes.containsAscii(#""type":"assistant""#) else { return }
                    guard line.bytes.containsAscii(#""usage""#) else { return }

                    autoreleasepool {
                        guard
                            let obj = try? ClaudeJSONObject.decode(line.bytes),
                            let type = obj["type"] as? String,
                            type == "assistant"
                        else { return }
                        let message = obj.dictionary("message")
                        guard Self.matchesClaudeProviderFilter(obj: obj, message: message, filter: providerFilter)
                        else { return }

                        guard let tsText = obj["timestamp"] as? String,
                              let parsedTimestamp = Self.claudeTimestampAndDayKey(tsText, calendar: range.calendar)
                        else { return }
                        let timestamp = parsedTimestamp.date
                        let dayKey = parsedTimestamp.dayKey

                        guard let message else { return }
                        guard let model = message["model"] as? String else { return }
                        guard let usage = message.dictionary("usage") else { return }

                        let input = max(0, toInt(usage["input_tokens"]))
                        let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
                        let cacheCreate1h = Self.claudeOneHourCacheCreationTokens(
                            usage: usage,
                            total: cacheCreate)
                        let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
                        let output = max(0, toInt(usage["output_tokens"]))
                        if input == 0, cacheCreate == 0, cacheRead == 0, output == 0 {
                            return
                        }

                        // Proxies may put a local, cache-unaware estimate in message_start.
                        // Missing stop_reason alone is not evidence of incomplete legacy usage.
                        let isIncomplete = message["stop_reason"] is NSNull && input > 0 && output == 0
                            && usage["cache_read_input_tokens"] == nil
                            && usage["cache_creation_input_tokens"] == nil
                        let cost = isIncomplete ? nil : pricingResolver.costUSD(
                            model: model,
                            inputTokens: input,
                            cacheReadInputTokens: cacheRead,
                            cacheCreationInputTokens: cacheCreate,
                            cacheCreationInputTokens1h: cacheCreate1h,
                            outputTokens: output,
                            pricingDate: timestamp)
                        let costNanos = cost.flatMap { Int(exactly: ($0 * costScale).rounded()) }
                        let tokens = ClaudeTokens(
                            input: input,
                            cacheRead: cacheRead,
                            cacheCreate: cacheCreate,
                            cacheCreate1h: cacheCreate1h,
                            output: output,
                            costNanos: costNanos ?? 0,
                            costPriced: costNanos != nil)

                        guard CostUsageDayRange.isInRange(
                            dayKey: dayKey,
                            since: range.scanSinceKey,
                            until: range.scanUntilKey)
                        else { return }

                        let messageId = message["id"] as? String
                        let requestId = obj["requestId"] as? String
                        let sessionId = obj["sessionId"] as? String
                            ?? obj["session_id"] as? String
                            ?? obj.dictionary("metadata")?["sessionId"] as? String
                            ?? message.dictionary("metadata")?["sessionId"] as? String
                        let normalizedModel = pricingResolver.normalize(model)
                        let row = ClaudeUsageRow(
                            dayKey: dayKey,
                            model: normalizedModel,
                            sessionId: sessionId,
                            messageId: messageId,
                            requestId: requestId,
                            timestampUnixMs: Int64((timestamp.timeIntervalSince1970 * 1000).rounded()),
                            isSidechain: toBool(obj["isSidechain"]),
                            pathRole: pathRole,
                            input: tokens.input,
                            cacheRead: tokens.cacheRead,
                            cacheCreate: tokens.cacheCreate,
                            cacheCreate1h: tokens.cacheCreate1h,
                            output: tokens.output,
                            costNanos: tokens.costNanos,
                            costPriced: tokens.costPriced,
                            isIncomplete: isIncomplete ? true : nil)

                        // Keep the final cumulative chunk for each response.
                        if let key = Self.claudeCanonicalRowKey(row) {
                            if Self.shouldReplaceClaudeRow(keyedRows[key], with: row) {
                                keyedRows[key] = row
                            }
                        } else {
                            unkeyedRows.append(row)
                        }
                    }
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            parsedBytes = startOffset
        }

        let rows = keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
        return ClaudeParseResult(rows: rows, parsedBytes: parsedBytes)
    }

    private static func claudeOneHourCacheCreationTokens(usage: ClaudeJSONObject, total: Int) -> Int {
        guard let cacheCreation = usage.dictionary("cache_creation") else { return 0 }
        let tokens = (cacheCreation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        return min(total, max(0, tokens))
    }

    private static func claudePathRole(fileURL: URL) -> ClaudePathRole {
        fileURL.path.contains("/subagents/") ? .subagent : .parent
    }

    private static func claudeCanonicalRowKey(_ row: ClaudeUsageRow) -> ClaudeRowKey? {
        guard let messageId = row.messageId else { return nil }
        if let requestId = row.requestId {
            return .request(messageId: messageId, requestId: requestId)
        }
        // Proxy responses can omit requestId while repeating usage for the same message.
        guard !messageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sessionId = row.sessionId,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return .session(sessionId: sessionId, messageId: messageId)
    }

    private static func shouldReplaceClaudeRow(_ existing: ClaudeUsageRow?, with row: ClaudeUsageRow) -> Bool {
        row.isIncomplete != true || existing == nil || existing?.isIncomplete == true
    }

    private static func mergeClaudeRows(existing: [ClaudeUsageRow], delta: [ClaudeUsageRow]) -> [ClaudeUsageRow] {
        var keyedRows: [ClaudeRowKey: ClaudeUsageRow] = [:]
        var unkeyedRows: [ClaudeUsageRow] = []

        for row in existing {
            if let key = Self.claudeCanonicalRowKey(row) {
                keyedRows[key] = row
            } else {
                unkeyedRows.append(row)
            }
        }
        for row in delta {
            if let key = Self.claudeCanonicalRowKey(row) {
                if Self.shouldReplaceClaudeRow(keyedRows[key], with: row) {
                    keyedRows[key] = row
                }
            } else {
                unkeyedRows.append(row)
            }
        }

        return keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
    }

    private static func claudeRowWins(
        lhs: (path: String, row: ClaudeUsageRow),
        rhs: (path: String, row: ClaudeUsageRow)) -> Bool
    {
        if (lhs.row.isIncomplete == true) != (rhs.row.isIncomplete == true) {
            return lhs.row.isIncomplete != true
        }
        if lhs.row.isSidechain != rhs.row.isSidechain {
            return rhs.row.isSidechain
        }
        if lhs.row.pathRole != rhs.row.pathRole {
            return rhs.row.pathRole == .subagent
        }
        return lhs.path < rhs.path
    }

    private static func reconciledClaudeRows(cache: CostUsageCache) -> [ClaudeUsageRow] {
        #if DEBUG
        recordClaudeScanWork(.reconcile)
        #endif
        var rows: [ClaudeUsageRow] = []
        var winners: [ClaudeRowKey: (path: String, row: ClaudeUsageRow)] = [:]

        for path in cache.files.keys.sorted() {
            guard let fileRows = cache.files[path]?.claudeRows else { continue }
            for row in fileRows {
                guard let canonicalKey = Self.claudeCanonicalRowKey(row) else {
                    rows.append(row)
                    continue
                }
                let candidate = (path: path, row: row)
                if let existing = winners[canonicalKey] {
                    if Self.claudeRowWins(lhs: candidate, rhs: existing) {
                        winners[canonicalKey] = candidate
                    }
                } else {
                    winners[canonicalKey] = candidate
                }
            }
        }

        rows.append(contentsOf: winners.keys.sorted().compactMap { winners[$0]?.row })
        return rows
    }

    private static func rebuildClaudeDays(cache: inout CostUsageCache) {
        var days: [String: [String: [Int]]] = [:]
        var overflowed: Set<ClaudeDayModelKey> = []

        for row in Self.reconciledClaudeRows(cache: cache) {
            let key = ClaudeDayModelKey(day: row.dayKey, model: row.model)
            guard !overflowed.contains(key) else { continue }
            var dayModels = days[row.dayKey] ?? [:]
            let packed = dayModels[row.model] ?? [0, 0, 0, 0, 0, 0, 0, 0]
            if row.isIncomplete == true {
                // Retain the day/model so missing usage is visible without treating it as zero activity.
                dayModels[row.model] = packed
                days[row.dayKey] = dayModels
                continue
            }
            let delta = [
                row.input,
                row.cacheRead,
                row.cacheCreate,
                row.output,
                row.costNanos,
                1,
                (row.costPriced ?? (row.costNanos > 0)) ? 1 : 0,
                row.cacheCreate1h ?? 0,
            ]
            let summed = zip(packed, delta).compactMap { current, incoming -> Int? in
                let sum = current.addingReportingOverflow(incoming)
                return sum.overflow ? nil : sum.partialValue
            }
            if summed.count == packed.count {
                dayModels[row.model] = summed
            } else {
                // Raw rows retain every metric; the legacy packed format cannot represent an unavailable total.
                overflowed.insert(key)
                dayModels.removeValue(forKey: row.model)
            }
            days[row.dayKey] = dayModels
        }

        cache.days = days
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
        obj: ClaudeJSONObject,
        message: ClaudeJSONObject?,
        filter: ClaudeLogProviderFilter) -> Bool
    {
        switch filter {
        case .all:
            true
        case .vertexAIOnly:
            self.isVertexAIUsageEntry(obj: obj, message: message)
        case .excludeVertexAI:
            !self.isVertexAIUsageEntry(obj: obj, message: message)
        }
    }

    static func isVertexAIUsageEntry(obj: Any) -> Bool {
        guard let obj = ClaudeJSONObject(obj) else { return false }
        return self.isVertexAIUsageEntry(obj: obj)
    }

    static func isVertexAIUsageEntry(obj: ClaudeJSONObject) -> Bool {
        self.isVertexAIUsageEntry(obj: obj, message: obj.dictionary("message"))
    }

    private static func isVertexAIUsageEntry(obj: ClaudeJSONObject, message: ClaudeJSONObject?) -> Bool {
        // Primary detection: Vertex AI message IDs and request IDs have "vrtx" prefix
        // e.g., "msg_vrtx_0154LUXjFVzQGUca3yK2RUeo", "req_vrtx_011CWjK86SWeFuXqZKUtgB1H"
        if let messageId = message?["id"] as? String,
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
        if let model = message?["model"] as? String,
           Self.modelNameLooksVertex(model)
        {
            return true
        }

        // The recursive walk already includes root and message metadata, requests, context, and client.
        return Self.containsVertexAIMetadata(in: obj)
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

    private static func containsVertexAIMetadata(in dict: ClaudeJSONObject) -> Bool {
        dict.contains { key, value in
            if self.containsClaudeVertexMarker(key, includeGCP: true) {
                return true
            }
            if self.vertexProviderKeys.contains(key.lowercased()),
               let text = value.string,
               self.containsClaudeVertexMarker(text)
            {
                return true
            }
            if let nested = value.dictionary {
                return self.containsVertexAIMetadata(in: nested)
            }
            // Array elements descend into dictionaries only, never into another array.
            return value.arrayContainsDictionary { self.containsVertexAIMetadata(in: $0) }
        }
    }

    private static func containsClaudeVertexMarker(_ value: String, includeGCP: Bool = false) -> Bool {
        let asciiMatch = value.utf8.withContiguousStorageIfAvailable { bytes -> Bool? in
            // Validate the entire decoded string before matching: a later combining scalar can
            // change Foundation's substring semantics even when the marker itself is ASCII.
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
            for index in bytes.indices {
                let first = bytes[index] | 0x20
                if first == 0x76, index + 5 < bytes.count, // vertex
                   bytes[index + 1] | 0x20 == 0x65,
                   bytes[index + 2] | 0x20 == 0x72,
                   bytes[index + 3] | 0x20 == 0x74,
                   bytes[index + 4] | 0x20 == 0x65,
                   bytes[index + 5] | 0x20 == 0x78
                {
                    return true
                }
                if includeGCP, first == 0x67, index + 2 < bytes.count, // gcp
                   bytes[index + 1] | 0x20 == 0x63,
                   bytes[index + 2] | 0x20 == 0x70
                {
                    return true
                }
            }
            return false
        }.flatMap(\.self)
        if let asciiMatch {
            return asciiMatch
        }

        let lower = value.lowercased()
        return lower.contains("vertex") || (includeGCP && lower.contains("gcp"))
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

    private struct ClaudeSourceFile {
        let url: URL
        let stamp: CostUsageClaudeFileStamp
    }

    private struct ClaudeSourceInventory {
        var files: [String: ClaudeSourceFile] = [:]

        var stamps: [String: CostUsageClaudeFileStamp] {
            self.files.mapValues(\.stamp)
        }
    }

    private final class ClaudeScanState {
        var cache: CostUsageCache
        var sourceFileIDs: [String: String]
        let range: CostUsageDayRange
        let providerFilter: ClaudeLogProviderFilter
        let forceFullScan: Bool
        let changedPaths: Set<String>
        let pricingResolver: CostUsagePricing.ClaudeResolver
        let checkCancellation: CancellationCheck?

        init(
            cache: CostUsageCache,
            sourceFileIDs: [String: String],
            range: CostUsageDayRange,
            providerFilter: ClaudeLogProviderFilter,
            forceFullScan: Bool,
            changedPaths: Set<String>,
            pricingResolver: CostUsagePricing.ClaudeResolver,
            checkCancellation: CancellationCheck?)
        {
            self.cache = cache
            self.sourceFileIDs = sourceFileIDs
            self.range = range
            self.providerFilter = providerFilter
            self.forceFullScan = forceFullScan
            self.changedPaths = changedPaths
            self.pricingResolver = pricingResolver
            self.checkCancellation = checkCancellation
        }
    }

    private static func processClaudeFile(
        source: ClaudeSourceFile,
        state: ClaudeScanState) throws
    {
        try state.checkCancellation?()
        let path = source.url.path
        let stamp = source.stamp
        let cached = state.cache.files[path]
        let sameFile = state.sourceFileIDs[path] == stamp.fileID

        if let cached, sameFile,
           cached.mtimeUnixMs == stamp.mtimeUnixMs,
           cached.size == stamp.size,
           !state.forceFullScan,
           !state.changedPaths.contains(path)
        {
            return
        }

        let startOffset: Int64 = if let cached, sameFile, !state.forceFullScan,
                                    stamp.size > cached.size,
                                    cached.claudeRows != nil,
                                    let parsedBytes = cached.parsedBytes, parsedBytes > 0, parsedBytes <= stamp.size
        {
            parsedBytes
        } else {
            0
        }

        state.pricingResolver.prepareCatalog()
        #if DEBUG
        Self.recordClaudeScanWork(.transcriptParse(startOffset: startOffset))
        #endif
        let parsed = try Self.parseClaudeFileCancellable(
            fileURL: source.url,
            range: state.range,
            providerFilter: state.providerFilter,
            startOffset: startOffset,
            pricingResolver: state.pricingResolver,
            checkCancellation: state.checkCancellation)
        let rows = startOffset > 0 ? Self.mergeClaudeRows(existing: cached?.claudeRows ?? [], delta: parsed.rows)
            : parsed.rows
        let usage = Self.makeFileUsage(
            mtimeUnixMs: stamp.mtimeUnixMs,
            size: stamp.size,
            days: [:],
            parsedBytes: parsed.parsedBytes,
            claudeRows: rows)
        state.cache.files[path] = usage
        state.sourceFileIDs[path] = stamp.fileID
    }

    private static func inventoryClaudeRoots(
        _ roots: [URL],
        checkCancellation: CancellationCheck?) throws -> ClaudeSourceInventory
    {
        var inventory = ClaudeSourceInventory()

        for root in roots {
            try checkCancellation?()
            let rootPath = root.path
            let rootCandidates = Self.claudeRootCandidates(for: rootPath)
            guard let existingRootPath = rootCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
            else { continue }
            let existingRoot = existingRootPath == rootPath ? root : URL(fileURLWithPath: existingRootPath)
            guard let enumerator = FileManager.default.enumerator(
                at: existingRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            for case let url as URL in enumerator {
                try checkCancellation?()
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                guard let stamp = CostUsageClaudeFileStamp.read(at: url), stamp.size > 0 else { continue }
                inventory.files[url.path] = ClaudeSourceFile(url: url, stamp: stamp)
            }
        }
        return inventory
    }

    static func loadClaudeDaily(
        provider: UsageProvider,
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        reportContext: CostUsageReportContext? = nil,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let roots = self.defaultClaudeProjectsRoots(options: options)
        let inventory = try Self.inventoryClaudeRoots(roots, checkCancellation: checkCancellation)
        try checkCancellation?()

        let cacheContext = reportContext ?? .regular
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(
            provider: provider,
            cacheRoot: options.cacheRoot,
            reportContext: cacheContext)
        let canonicalCachePath = cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
        let cacheArtifactStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        let pricingURL = ModelsDevCache.cacheFileURL(cacheRoot: options.cacheRoot)
        let pricingArtifactStamp = CostUsageClaudeFileStamp.read(at: pricingURL)
        let reportKey = Self.claudeReportMemoKey(
            provider: provider,
            providerFilter: options.claudeLogProviderFilter,
            range: range,
            roots: roots,
            artifactStamps: (cache: cacheArtifactStamp, pricing: pricingArtifactStamp))
        let memo = CostUsageClaudeReportMemo.shared
        let priorMemo = memo.entry(provider: provider, canonicalCachePath: canonicalCachePath)
        let sourceInventory = inventory.stamps

        if !options.forceRescan,
           let priorMemo,
           reportContext == nil || priorMemo.hasWindowScopedRows,
           priorMemo.sourceInventory == sourceInventory,
           priorMemo.reportKey == reportKey
        {
            try checkCancellation?()
            return priorMemo.report
        }

        var artifact = CostUsageClaudeCacheIO.load(
            provider: provider,
            cacheRoot: options.cacheRoot,
            reportContext: cacheContext,
            calendar: range.calendar)
        var cache = artifact.usage
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        // Matching bounds alone cannot prove that legacy partial scans retained each file's narrow-window winner.
        let hasWindowScopedBaseline = priorMemo?.certifiesWindow(reportKey: reportKey, cache: cache) == true
        let needsWindowScopedRebuild = reportContext != nil && !hasWindowScopedBaseline
        let sourceInventoryChanged = priorMemo.map { $0.sourceInventory != sourceInventory } ?? false
        let cacheArtifactChanged = priorMemo.map {
            $0.reportKey.cacheArtifactStamp != cacheArtifactStamp
        } ?? false
        let scanConfigurationChanged = priorMemo.map {
            $0.reportKey.scanConfiguration != reportKey.scanConfiguration
        } ?? false
        let sourceIdentitiesChanged = artifact.sourceFileIDs != sourceInventory.mapValues(\.fileID)
        let shouldRefresh = options.forceRescan
            || sourceIdentitiesChanged
            || windowExpanded
            || needsWindowScopedRebuild
            || sourceInventoryChanged
            || cacheArtifactChanged
            || scanConfigurationChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs
        let providerFilter = options.claudeLogProviderFilter
        let hasStableProcessBaseline = priorMemo != nil
            && !sourceIdentitiesChanged
            && !sourceInventoryChanged
            && !cacheArtifactChanged
            && !scanConfigurationChanged
        let shouldMutateCache = shouldRefresh && (
            !hasStableProcessBaseline || options.forceRescan || windowExpanded || needsWindowScopedRebuild)
        let forceFullScan = options
            .forceRescan || windowExpanded || scanConfigurationChanged || needsWindowScopedRebuild
        let pricingResolver = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: options.cacheRoot)

        if shouldMutateCache {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
                artifact.sourceFileIDs = [:]
            }
            let changedPaths: Set<String> = if let priorMemo {
                Set(inventory.files.keys.filter { path in
                    priorMemo.sourceInventory[path] != sourceInventory[path]
                })
            } else {
                []
            }
            let scanState = ClaudeScanState(
                cache: cache,
                sourceFileIDs: artifact.sourceFileIDs,
                range: range,
                providerFilter: providerFilter,
                forceFullScan: forceFullScan,
                changedPaths: changedPaths,
                pricingResolver: pricingResolver,
                checkCancellation: checkCancellation)

            for path in inventory.files.keys.sorted() {
                guard let source = inventory.files[path] else { continue }
                try Self.processClaudeFile(source: source, state: scanState)
            }
            try checkCancellation?()

            cache = scanState.cache
            artifact.sourceFileIDs = scanState.sourceFileIDs.filter { sourceInventory[$0.key] != nil }
            cache.roots = nil

            for key in cache.files.keys where sourceInventory[key] == nil {
                cache.files.removeValue(forKey: key)
            }

            Self.rebuildClaudeDays(cache: &cache)
            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
        }

        let report = Self.buildClaudeReportFromCache(
            cache: cache,
            range: range,
            pricingResolver: pricingResolver)
        try checkCancellation?()

        artifact.usage = cache
        let committedCacheStamp: CostUsageClaudeFileStamp? = if shouldMutateCache {
            try CostUsageClaudeCacheIO.save(
                provider: provider,
                cache: artifact,
                cacheRoot: options.cacheRoot,
                reportContext: cacheContext,
                calendar: range.calendar,
                checkCancellation: checkCancellation)
        } else {
            nil
        }

        let finalCacheArtifactStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        let finalPricingArtifactStamp = CostUsageClaudeFileStamp.read(at: pricingURL)
        let finalReportKey = Self.claudeReportMemoKey(
            provider: provider,
            providerFilter: providerFilter,
            range: range,
            roots: roots,
            artifactStamps: (cache: finalCacheArtifactStamp, pricing: finalPricingArtifactStamp))
        let cacheArtifactIsCurrent = if shouldMutateCache {
            committedCacheStamp != nil && finalCacheArtifactStamp == committedCacheStamp
        } else {
            finalCacheArtifactStamp == cacheArtifactStamp
        }
        if cacheArtifactIsCurrent, finalPricingArtifactStamp == pricingArtifactStamp {
            memo.store(
                provider: provider,
                canonicalCachePath: canonicalCachePath,
                sourceInventory: sourceInventory,
                reportKey: finalReportKey,
                report: report,
                hasWindowScopedRows: hasWindowScopedBaseline || (shouldMutateCache && forceFullScan))
        }
        return report
    }

    private static func claudeReportMemoKey(
        provider: UsageProvider,
        providerFilter: ClaudeLogProviderFilter,
        range: CostUsageDayRange,
        roots: [URL],
        artifactStamps: (cache: CostUsageClaudeFileStamp?, pricing: CostUsageClaudeFileStamp?))
        -> CostUsageClaudeReportMemoKey
    {
        let providerFilterKey = switch providerFilter {
        case .all: "all"
        case .vertexAIOnly: "vertex-ai-only"
        case .excludeVertexAI: "exclude-vertex-ai"
        }
        return CostUsageClaudeReportMemoKey(
            provider: provider,
            providerFilter: providerFilterKey,
            sinceKey: range.sinceKey,
            untilKey: range.untilKey,
            scanSinceKey: range.scanSinceKey,
            scanUntilKey: range.scanUntilKey,
            timeZoneIdentifier: range.calendar.timeZone.identifier,
            roots: roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.sorted(),
            cacheArtifactStamp: artifactStamps.cache,
            pricingArtifactStamp: artifactStamps.pricing)
    }

    static func buildClaudeReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        now: Date = Date(),
        modelsDevCacheRoot: URL? = nil) -> CostUsageDailyReport
    {
        self.buildClaudeReportFromCache(
            cache: cache,
            range: range,
            pricingResolver: CostUsagePricing.ClaudeResolver(now: now, cacheRoot: modelsDevCacheRoot))
    }

    private static func buildClaudeReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> CostUsageDailyReport
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var temporalBuckets = TemporalBuckets()
        var totalInput = CostUsageDailyReport.OptionalCountAccumulator(0)
        var totalOutput = CostUsageDailyReport.OptionalCountAccumulator(0)
        var totalCacheRead = CostUsageDailyReport.OptionalCountAccumulator(0)
        var totalCacheCreate = CostUsageDailyReport.OptionalCountAccumulator(0)
        var totalTokens = CostUsageDailyReport.OptionalCountAccumulator(0)
        var totalCost: Double = 0
        var costSeen = false
        var hasTokens = false
        let repricedCosts = self.claudeTemporalPricing(
            rows: Self.reconciledClaudeRows(cache: cache),
            range: range,
            pricingResolver: pricingResolver,
            temporalBuckets: &temporalBuckets)

        let hasCompleteRows = !cache.files.isEmpty && cache.files.values.allSatisfy { $0.claudeRows != nil }
        let modelsByDay = hasCompleteRows
            ? Dictionary(grouping: repricedCosts.keys, by: \.day).mapValues { $0.map(\.model).sorted() }
            : cache.days.mapValues { $0.keys.sorted() }
        let dayKeys = modelsByDay.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        for day in dayKeys {
            let modelNames = modelsByDay[day] ?? []

            var dayInput = CostUsageDailyReport.OptionalCountAccumulator(0)
            var dayOutput = CostUsageDailyReport.OptionalCountAccumulator(0)
            var dayCacheRead = CostUsageDailyReport.OptionalCountAccumulator(0)
            var dayCacheCreate = CostUsageDailyReport.OptionalCountAccumulator(0)
            var daySampleCount = CostUsageDailyReport.OptionalCountAccumulator(0)
            var dayHasTokens = false
            var dayIncompleteCount = 0
            var dayPricedCount = CostUsageDailyReport.OptionalCountAccumulator(0)

            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for model in modelNames {
                let repricedCost = repricedCosts[ClaudeDayModelKey(day: day, model: model)]
                let counts = hasCompleteRows
                    ? repricedCost ?? ClaudeReportAggregate()
                    : ClaudeReportAggregate(packed: cache.days[day]?[model] ?? [])
                let sampleCount = counts.sampleCount
                daySampleCount.add(sampleCount)
                dayHasTokens = dayHasTokens || sampleCount > 0

                // Cache tokens are tracked separately; totalTokens includes input + cache.
                dayInput.merge(counts.input)
                dayCacheRead.merge(counts.cacheRead)
                dayCacheCreate.merge(counts.cacheCreate)
                dayOutput.merge(counts.output)

                let incompleteCount = repricedCost?.incompleteRequestCount ?? 0
                dayIncompleteCount += incompleteCount
                let currentPricingCost: Double? = if let repricedCost,
                                                     sampleCount > 0,
                                                     repricedCost.sampleCount == sampleCount,
                                                     !repricedCost.unresolved,
                                                     repricedCost.total.isFinite
                {
                    repricedCost.total
                } else {
                    nil
                }
                let cost = currentPricingCost
                breakdown.append(
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: cost,
                        totalTokens: sampleCount > 0 ? counts.totalTokens : nil,
                        incompleteRequestCount: incompleteCount > 0 ? incompleteCount : nil))
                if let cost {
                    dayPricedCount.add(sampleCount)
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let sortedBreakdown = Self.sortedModelBreakdowns(breakdown)

            var dayTokens = dayInput
            dayTokens.merge(dayCacheRead)
            dayTokens.merge(dayCacheCreate)
            dayTokens.merge(dayOutput)
            let dayTotal = dayTokens.value
            let entryCost = dayCostSeen && dayCost.isFinite ? dayCost : nil
            let unpricedCount = daySampleCount.value.flatMap { samples in
                dayPricedCount.value.map { samples - $0 }
            }
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayHasTokens ? dayInput.value : nil,
                outputTokens: dayHasTokens ? dayOutput.value : nil,
                cacheReadTokens: dayHasTokens ? dayCacheRead.value : nil,
                cacheCreationTokens: dayHasTokens ? dayCacheCreate.value : nil,
                totalTokens: dayHasTokens ? dayTotal : nil,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: sortedBreakdown,
                unpricedRequestCount: dayIncompleteCount > 0 ? unpricedCount : nil,
                unmeteredRequestCount: dayIncompleteCount > 0 ? dayIncompleteCount : nil,
                estimatedRequestCount: dayIncompleteCount > 0 ? dayPricedCount.value : nil))

            hasTokens = hasTokens || dayHasTokens
            totalInput.merge(dayInput)
            totalOutput.merge(dayOutput)
            totalCacheRead.merge(dayCacheRead)
            totalCacheCreate.merge(dayCacheCreate)
            totalTokens.merge(dayTokens)
            if let entryCost {
                totalCost += entryCost
                costSeen = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: hasTokens ? totalInput.value : nil,
                totalOutputTokens: hasTokens ? totalOutput.value : nil,
                cacheReadTokens: hasTokens ? totalCacheRead.value : nil,
                cacheCreationTokens: hasTokens ? totalCacheCreate.value : nil,
                totalTokens: hasTokens ? totalTokens.value : nil,
                totalCostUSD: costSeen && totalCost.isFinite ? totalCost : nil)

        return CostUsageDailyReport(
            data: entries,
            summary: summary,
            hourly: self.sortedHourlyEntries(temporalBuckets.hourly),
            quotaSlices: self.sortedQuotaSlices(temporalBuckets.quotaSlices))
    }

    private static func claudeTemporalPricing(
        rows: [ClaudeUsageRow],
        range: CostUsageDayRange,
        pricingResolver: CostUsagePricing.ClaudeResolver,
        temporalBuckets: inout TemporalBuckets) -> [ClaudeDayModelKey: ClaudeReportAggregate]
    {
        let costScale = 1_000_000_000.0
        var repricedCosts: [ClaudeDayModelKey: ClaudeReportAggregate] = [:]
        if !rows.isEmpty {
            pricingResolver.prepareCatalog()
        }

        for row in rows {
            #if DEBUG
            Self.recordClaudeScanWork(.reprice)
            #endif
            let key = ClaudeDayModelKey(day: row.dayKey, model: row.model)
            var aggregate = repricedCosts[key] ?? ClaudeReportAggregate()
            if row.isIncomplete == true {
                aggregate.incompleteRequestCount += 1
                repricedCosts[key] = aggregate
                continue
            }
            aggregate.sampleCount += 1
            aggregate.input.add(row.input)
            aggregate.output.add(row.output)
            aggregate.cacheRead.add(row.cacheRead)
            aggregate.cacheCreate.add(row.cacheCreate)
            let isPriced = row.costPriced ?? (row.costNanos > 0)
            let currentPricingCost = pricingResolver.costUSD(
                model: row.model,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreate,
                cacheCreationInputTokens1h: row.cacheCreate1h ?? 0,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map {
                    Date(timeIntervalSince1970: Double($0) / 1000)
                })
            let cost: Double? = if isPriced, row.costNanos == 0 {
                0
            } else if let currentPricingCost {
                currentPricingCost
            } else if isPriced {
                Double(row.costNanos) / costScale
            } else {
                nil
            }
            if let cost {
                aggregate.total += cost
            } else {
                aggregate.unresolved = true
            }
            repricedCosts[key] = aggregate

            self.addClaudeTemporal(row: row, costUSD: cost, range: range, into: &temporalBuckets)
        }

        return repricedCosts
    }
}
