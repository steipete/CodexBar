import Foundation

extension CostUsageScanner {
    // MARK: - Claude

    private final class ClaudeReportMemoHitObserverStore: @unchecked Sendable {
        let observer: () -> Void

        init(observer: @escaping () -> Void) {
            self.observer = observer
        }
    }

    @TaskLocal private static var claudeReportMemoHitObserverStore: ClaudeReportMemoHitObserverStore?

    static func withClaudeReportMemoHitObserverForTesting<T>(
        _ observer: @escaping () -> Void,
        operation: () throws -> T) rethrows -> T
    {
        try self.$claudeReportMemoHitObserverStore.withValue(.init(observer: observer)) {
            try operation()
        }
    }

    private struct ClaudeTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int
        let output: Int
        let costNanos: Int
        let costPriced: Bool
    }

    private struct ClaudeRawTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int
        let output: Int
    }

    private struct ClaudeDayModelKey: Hashable {
        let day: String
        let model: String
        let attribution: CostUsageAttribution?
    }

    private struct ClaudeRepricedCost {
        var total: Double = 0
        var sampleCount: Int = 0
        var unresolved = false
    }

    private struct ClaudeModelResolution {
        let normalizedModel: String
        let cost: Double?
        let attribution: CostUsageAttribution?
    }

    private struct ClaudeModelResolutionContext {
        let pricingDate: Date
        let sessionID: String?
        let timestampUnixMs: Int64?
        let attributionResolver: CLIProxyAPIAttributionResolver?
        let pricingResolver: CostUsagePricing.ClaudeResolver
    }

    private static func resolveClaudeModel(
        model: String,
        tokens: ClaudeRawTokens,
        context: ClaudeModelResolutionContext) -> ClaudeModelResolution
    {
        let modelsDevCatalog = context.pricingResolver.prepareCatalog()
        let modelProvider = CostUsagePricing.modelProvider(
            for: model,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: nil)
        let resolvedAttribution = context.attributionResolver?.attribution(
            model: model,
            modelProvider: modelProvider,
            sessionID: context.sessionID,
            timestampUnixMs: context.timestampUnixMs,
            tokens: .init(
                input: tokens.input,
                cacheRead: tokens.cacheRead,
                cacheCreate: tokens.cacheCreate,
                output: tokens.output))
            ?? CostUsageAttribution(
                client: .claudeCode,
                route: .unknown,
                modelProvider: modelProvider,
                evidence: [.modelProvider])
        let attribution = resolvedAttribution.route == .cliProxyAPI ? resolvedAttribution : nil
        let upstreamModel = resolvedAttribution.route == .cliProxyAPI
            ? resolvedAttribution.upstream?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let pricingModel = upstreamModel.flatMap { $0.isEmpty ? nil : $0 } ?? model
        let pricingProvider = CostUsagePricing.modelProvider(
            for: pricingModel,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: nil)
        let cost: Double? = if resolvedAttribution.route != .cliProxyAPI {
            context.pricingResolver.costUSD(
                model: model,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                cacheCreationInputTokens1h: tokens.cacheCreate1h,
                outputTokens: tokens.output,
                pricingDate: context.pricingDate)
        } else if pricingProvider == .openAI {
            CostUsagePricing.claudeProxyCodexCostUSD(
                model: pricingModel,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                outputTokens: tokens.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: nil)
        } else if pricingProvider == .anthropic {
            context.pricingResolver.costUSD(
                model: pricingModel,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                cacheCreationInputTokens1h: tokens.cacheCreate1h,
                outputTokens: tokens.output,
                pricingDate: context.pricingDate)
        } else if pricingProvider == .google {
            CostUsagePricing.claudeProxyGoogleCostUSD(
                model: pricingModel,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                outputTokens: tokens.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: nil)
        } else if pricingProvider == .other {
            context.pricingResolver.costUSD(
                model: pricingModel,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                cacheCreationInputTokens1h: tokens.cacheCreate1h,
                outputTokens: tokens.output,
                pricingDate: context.pricingDate)
        } else { nil }
        let normalizedModel = context.pricingResolver.normalize(model)
        return ClaudeModelResolution(
            normalizedModel: normalizedModel,
            cost: cost,
            attribution: attribution)
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
        attributionResolver: CLIProxyAPIAttributionResolver? = nil,
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
                attributionResolver: attributionResolver,
                pricingResolver: pricingResolver,
                checkCancellation: nil)) ?? ClaudeParseResult(rows: [], parsedBytes: startOffset)
    }

    static func parseClaudeFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        attributionResolver: CLIProxyAPIAttributionResolver? = nil,
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
        var keyedRows: [String: ClaudeUsageRow] = [:]
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

                        let rawTokens = ClaudeRawTokens(
                            input: input,
                            cacheRead: cacheRead,
                            cacheCreate: cacheCreate,
                            cacheCreate1h: cacheCreate1h,
                            output: output)
                        let sessionId = obj["sessionId"] as? String
                            ?? obj["session_id"] as? String
                            ?? obj.dictionary("metadata")?["sessionId"] as? String
                            ?? message.dictionary("metadata")?["sessionId"] as? String
                        let timestampUnixMs = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
                        let modelResolution = Self.resolveClaudeModel(
                            model: model,
                            tokens: rawTokens,
                            context: ClaudeModelResolutionContext(
                                pricingDate: timestamp,
                                sessionID: sessionId,
                                timestampUnixMs: timestampUnixMs,
                                attributionResolver: attributionResolver,
                                pricingResolver: pricingResolver))
                        let costNanos = modelResolution.cost.map { Int(($0 * costScale).rounded()) } ?? 0
                        let tokens = ClaudeTokens(
                            input: input,
                            cacheRead: cacheRead,
                            cacheCreate: cacheCreate,
                            cacheCreate1h: cacheCreate1h,
                            output: output,
                            costNanos: costNanos,
                            costPriced: modelResolution.cost != nil)

                        guard CostUsageDayRange.isInRange(
                            dayKey: dayKey,
                            since: range.scanSinceKey,
                            until: range.scanUntilKey)
                        else { return }

                        let messageId = message["id"] as? String
                        let requestId = obj["requestId"] as? String
                        let row = ClaudeUsageRow(
                            dayKey: dayKey,
                            model: modelResolution.normalizedModel,
                            sessionId: sessionId,
                            messageId: messageId,
                            requestId: requestId,
                            timestampUnixMs: timestampUnixMs,
                            isSidechain: toBool(obj["isSidechain"]),
                            pathRole: pathRole,
                            input: tokens.input,
                            cacheRead: tokens.cacheRead,
                            cacheCreate: tokens.cacheCreate,
                            cacheCreate1h: tokens.cacheCreate1h,
                            output: tokens.output,
                            costNanos: tokens.costNanos,
                            costPriced: tokens.costPriced,
                            attribution: modelResolution.attribution)

                        // Streaming chunks share message.id + requestId inside a file.
                        // Keep overwriting so the final cumulative chunk wins.
                        if let messageId, let requestId {
                            let key = "\(messageId):\(requestId)"
                            keyedRows[key] = row
                        } else {
                            // Older logs omit IDs; treat each line as distinct to avoid dropping usage.
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

    private static func claudeCanonicalRowKey(_ row: ClaudeUsageRow) -> String? {
        guard let messageId = row.messageId, let requestId = row.requestId else {
            return nil
        }
        return "\(messageId):\(requestId)"
    }

    private static func mergeClaudeRows(existing: [ClaudeUsageRow], delta: [ClaudeUsageRow]) -> [ClaudeUsageRow] {
        var keyedRows: [String: ClaudeUsageRow] = [:]
        var unkeyedRows: [ClaudeUsageRow] = []

        for row in existing {
            if let key = Self.claudeInFileKey(row) {
                keyedRows[key] = row
            } else {
                unkeyedRows.append(row)
            }
        }
        for row in delta {
            if let key = Self.claudeInFileKey(row) {
                keyedRows[key] = row
            } else {
                unkeyedRows.append(row)
            }
        }

        return keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
    }

    private static func claudeInFileKey(_ row: ClaudeUsageRow) -> String? {
        guard let messageId = row.messageId, let requestId = row.requestId else { return nil }
        return "\(messageId):\(requestId)"
    }

    private static func claudeRowWins(
        lhs: (path: String, row: ClaudeUsageRow),
        rhs: (path: String, row: ClaudeUsageRow)) -> Bool
    {
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
        var winners: [String: (path: String, row: ClaudeUsageRow)] = [:]

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

    private static func claudeAttributionReconciliationRows(
        cache: CostUsageCache) -> [(key: ClaudeAttributionReconciliationKey, row: ClaudeUsageRow)]
    {
        var rows: [(key: ClaudeAttributionReconciliationKey, row: ClaudeUsageRow)] = []
        var winners: [String: (path: String, row: ClaudeUsageRow)] = [:]

        for path in cache.files.keys.sorted() {
            guard let fileRows = cache.files[path]?.claudeRows else { continue }
            for (index, row) in fileRows.enumerated() {
                guard let canonicalKey = Self.claudeCanonicalRowKey(row) else {
                    rows.append((key: .unkeyed(path: path, index: index), row: row))
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

        rows.append(contentsOf: winners.keys.sorted().compactMap { key in
            winners[key].map { (key: .canonical(key), row: $0.row) }
        })
        return rows
    }

    private enum ClaudeAttributionReconciliationKey: Hashable {
        case canonical(String)
        case unkeyed(path: String, index: Int)
    }

    private struct ClaudeAttributionReconciliationItem {
        let key: ClaudeAttributionReconciliationKey
        let request: CLIProxyAPIAttributionResolver.Request
        let modelProvider: CostUsageAttribution.ModelProvider
        let cachedAttribution: CostUsageAttribution?
    }

    private static func reconcileClaudeAttributions(
        cache: inout CostUsageCache,
        attributionResolver: CLIProxyAPIAttributionResolver,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?)
    {
        let items = Self.claudeAttributionReconciliationRows(cache: cache).map { item in
            let row = item.row
            let modelProvider = if let cachedProvider = row.attribution?.modelProvider,
                                   cachedProvider != .unknown
            {
                cachedProvider
            } else {
                CostUsagePricing.modelProvider(
                    for: row.model,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
            }
            return ClaudeAttributionReconciliationItem(
                key: item.key,
                request: CLIProxyAPIAttributionResolver.Request(
                    model: row.model,
                    modelProvider: modelProvider,
                    sessionID: row.sessionId,
                    timestampUnixMs: row.timestampUnixMs,
                    tokens: .init(
                        input: row.input,
                        cacheRead: row.cacheRead,
                        cacheCreate: row.cacheCreate,
                        output: row.output),
                    occurrenceID: row.messageId),
                modelProvider: modelProvider,
                cachedAttribution: row.attribution)
        }
        let requests = items.map(\.request)
        let liveAttributions = attributionResolver.attributions(for: requests)
        var replacementKeys: Set<ClaudeAttributionReconciliationKey> = []
        var replacements: [ClaudeAttributionReconciliationKey: CostUsageAttribution] = [:]
        for (index, item) in items.enumerated() {
            let liveAttribution = liveAttributions[index]
            guard liveAttribution.route == .cliProxyAPI
                || attributionResolver.hasMatchingObservation(for: item.request)
            else { continue }
            replacementKeys.insert(item.key)
            let replacement: CostUsageAttribution? = if liveAttribution.route == .cliProxyAPI {
                Self.preferredCLIProxyAPIAttribution(
                    live: liveAttribution,
                    cached: item.cachedAttribution)
            } else if item.modelProvider != .anthropic {
                liveAttribution
            } else {
                nil
            }
            replacements[item.key] = replacement
        }
        guard !replacementKeys.isEmpty else { return }

        for path in cache.files.keys {
            guard var file = cache.files[path], let rows = file.claudeRows else { continue }
            file.claudeRows = rows.enumerated().map { index, row in
                let key = Self.claudeCanonicalRowKey(row).map(ClaudeAttributionReconciliationKey.canonical)
                    ?? .unkeyed(path: path, index: index)
                guard replacementKeys.contains(key) else { return row }
                return ClaudeUsageRow(
                    dayKey: row.dayKey,
                    model: row.model,
                    sessionId: row.sessionId,
                    messageId: row.messageId,
                    requestId: row.requestId,
                    timestampUnixMs: row.timestampUnixMs,
                    isSidechain: row.isSidechain,
                    pathRole: row.pathRole,
                    input: row.input,
                    cacheRead: row.cacheRead,
                    cacheCreate: row.cacheCreate,
                    cacheCreate1h: row.cacheCreate1h,
                    output: row.output,
                    costNanos: row.costNanos,
                    costPriced: row.costPriced,
                    attribution: replacements[key])
            }
            cache.files[path] = file
        }
    }

    private static func removeCachedCLIProxyAPIAttribution(cache: inout CostUsageCache) {
        for path in cache.files.keys {
            guard var file = cache.files[path], let rows = file.claudeRows else { continue }
            file.claudeRows = rows.map { row in
                guard row.attribution?.route == .cliProxyAPI else { return row }
                return ClaudeUsageRow(
                    dayKey: row.dayKey,
                    model: row.model,
                    sessionId: row.sessionId,
                    messageId: row.messageId,
                    requestId: row.requestId,
                    timestampUnixMs: row.timestampUnixMs,
                    isSidechain: row.isSidechain,
                    pathRole: row.pathRole,
                    input: row.input,
                    cacheRead: row.cacheRead,
                    cacheCreate: row.cacheCreate,
                    cacheCreate1h: row.cacheCreate1h,
                    output: row.output,
                    costNanos: row.costNanos,
                    costPriced: row.costPriced,
                    attribution: nil)
            }
            cache.files[path] = file
        }
        self.rebuildClaudeDays(cache: &cache)
    }

    private static func rebuildClaudeDays(cache: inout CostUsageCache) {
        var days: [String: [String: [Int]]] = [:]

        for row in Self.reconciledClaudeRows(cache: cache) {
            var dayModels = days[row.dayKey] ?? [:]
            var packed = dayModels[row.model] ?? [0, 0, 0, 0, 0, 0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + row.input
            packed[1] = (packed[safe: 1] ?? 0) + row.cacheRead
            packed[2] = (packed[safe: 2] ?? 0) + row.cacheCreate
            packed[3] = (packed[safe: 3] ?? 0) + row.output
            packed[4] = (packed[safe: 4] ?? 0) + row.costNanos
            packed[5] = (packed[safe: 5] ?? 0) + 1
            packed[6] = (packed[safe: 6] ?? 0) + ((row.costPriced ?? (row.costNanos > 0)) ? 1 : 0)
            packed[7] = (packed[safe: 7] ?? 0) + (row.cacheCreate1h ?? 0)
            dayModels[row.model] = packed
            days[row.dayKey] = dayModels
        }

        cache.days = days
    }

    private static func makeClaudeFileUsage(
        mtimeMs: Int64,
        size: Int64,
        rows: [ClaudeUsageRow],
        parsedBytes: Int64?) -> CostUsageFileUsage
    {
        makeFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            days: [:],
            parsedBytes: parsedBytes,
            claudeRows: rows)
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
            if self.containsClaudeVertexMarker(key, includeGCP: true) { return true }
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
        if let asciiMatch { return asciiMatch }

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
        let range: CostUsageDayRange
        let providerFilter: ClaudeLogProviderFilter
        let forceFullScan: Bool
        let changedPaths: Set<String>
        let attributionResolver: CLIProxyAPIAttributionResolver?
        let pricingResolver: CostUsagePricing.ClaudeResolver
        let checkCancellation: CancellationCheck?

        init(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            providerFilter: ClaudeLogProviderFilter,
            forceFullScan: Bool,
            changedPaths: Set<String>,
            attributionResolver: CLIProxyAPIAttributionResolver?,
            pricingResolver: CostUsagePricing.ClaudeResolver,
            checkCancellation: CancellationCheck?)
        {
            self.cache = cache
            self.range = range
            self.providerFilter = providerFilter
            self.forceFullScan = forceFullScan
            self.changedPaths = changedPaths
            self.attributionResolver = attributionResolver
            self.pricingResolver = pricingResolver
            self.checkCancellation = checkCancellation
        }
    }

    private static func processClaudeFile(
        url: URL,
        size: Int64,
        mtimeMs: Int64,
        state: ClaudeScanState) throws
    {
        try state.checkCancellation?()
        let path = url.path

        if let cached = state.cache.files[path],
           cached.mtimeUnixMs == mtimeMs,
           cached.size == size,
           !state.forceFullScan,
           !state.changedPaths.contains(path)
        {
            return
        }

        state.pricingResolver.prepareCatalog()
        if let cached = state.cache.files[path], !state.forceFullScan {
            let startOffset = cached.parsedBytes ?? cached.size
            let canIncremental = size > cached.size && startOffset > 0 && startOffset <= size
                && cached.claudeRows != nil
            if canIncremental {
                #if DEBUG
                Self.recordClaudeScanWork(.transcriptParse)
                #endif
                let delta = try Self.parseClaudeFileCancellable(
                    fileURL: url,
                    range: state.range,
                    providerFilter: state.providerFilter,
                    startOffset: startOffset,
                    attributionResolver: state.attributionResolver,
                    pricingResolver: state.pricingResolver,
                    checkCancellation: state.checkCancellation)
                let mergedRows = Self.mergeClaudeRows(existing: cached.claudeRows ?? [], delta: delta.rows)
                state.cache.files[path] = Self.makeClaudeFileUsage(
                    mtimeMs: mtimeMs,
                    size: size,
                    rows: mergedRows,
                    parsedBytes: delta.parsedBytes)
                return
            }
        }

        #if DEBUG
        Self.recordClaudeScanWork(.transcriptParse)
        #endif
        let parsed = try Self.parseClaudeFileCancellable(
            fileURL: url,
            range: state.range,
            providerFilter: state.providerFilter,
            attributionResolver: state.attributionResolver,
            pricingResolver: state.pricingResolver,
            checkCancellation: state.checkCancellation)
        let usage = Self.makeClaudeFileUsage(
            mtimeMs: mtimeMs,
            size: size,
            rows: parsed.rows,
            parsedBytes: parsed.parsedBytes)
        state.cache.files[path] = usage
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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func loadClaudeDaily(
        provider: UsageProvider,
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let cliProxyAPIAttributionState = try self.captureClaudeCLIProxyAPIAttributionState(
            options: options,
            checkCancellation: checkCancellation)
        self.claudeCLIProxyAPIAttributionCaptureObserverStore?.observer()
        let cliProxyAPIConfigurationGeneration = cliProxyAPIAttributionState.configurationGeneration
        let cliProxyAPIAttributionEnabled = cliProxyAPIAttributionState.attributionEnabled
        let attributionResolver = cliProxyAPIAttributionState.resolver
        let cliProxyUsageArtifactStamp = cliProxyAPIAttributionState.usageArtifactStamp
        let cliProxyAPIInputArtifactFingerprint = cliProxyAPIAttributionState.inputArtifactFingerprint
        let roots = self.defaultClaudeProjectsRoots(options: options)
        let inventory = try Self.inventoryClaudeRoots(roots, checkCancellation: checkCancellation)
        try checkCancellation?()

        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: provider, cacheRoot: options.cacheRoot)
        let canonicalCachePath = cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
        let cacheArtifactStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        let pricingURL = ModelsDevCache.cacheFileURL(cacheRoot: options.cacheRoot)
        let pricingArtifactStamp = CostUsageClaudeFileStamp.read(at: pricingURL)
        let cliProxyUsageURL = CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: options.cacheRoot)
        let reportKey = Self.claudeReportMemoKey(
            provider: provider,
            providerFilter: options.claudeLogProviderFilter,
            attributionFilter: options.claudeAttributionFilter,
            cliProxyAPIConfigurationGeneration: cliProxyAPIConfigurationGeneration,
            cliProxyAPIAttributionEnabled: cliProxyAPIAttributionEnabled,
            cliProxyAPIInputArtifactFingerprint: cliProxyAPIInputArtifactFingerprint,
            range: range,
            roots: roots,
            artifactStamps: (
                cache: cacheArtifactStamp,
                pricing: pricingArtifactStamp,
                proxyUsage: cliProxyUsageArtifactStamp))
        let memo = CostUsageClaudeReportMemo.shared
        let priorMemo = memo.entry(provider: provider, canonicalCachePath: canonicalCachePath)
        let sourceInventory = inventory.stamps

        if !options.forceRescan,
           let priorMemo,
           priorMemo.sourceInventory == sourceInventory,
           priorMemo.reportKey == reportKey
        {
            self.claudeReportMemoHitObserverStore?.observer()
            try checkCancellation?()
            return try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                stateRoot: options.cacheRoot)
            {
                guard CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                    stateRoot: options.cacheRoot) == cliProxyAPIConfigurationGeneration
                else { throw CancellationError() }
                guard !CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
                    stateRoot: options.cacheRoot) == cliProxyAPIAttributionEnabled
                else { throw CancellationError() }
                guard CostUsageClaudeFileStamp.read(at: cliProxyUsageURL) == cliProxyUsageArtifactStamp
                else { throw CancellationError() }
                guard try Self.currentClaudeCLIProxyAPIInputArtifactFingerprint(
                    options: options,
                    attributionEnabled: cliProxyAPIAttributionEnabled,
                    checkCancellation: checkCancellation) == cliProxyAPIInputArtifactFingerprint
                else { throw CancellationError() }
                return priorMemo.report
            }
        }

        var cache = CostUsageClaudeCacheIO.load(
            provider: provider,
            cacheRoot: options.cacheRoot,
            calendar: range.calendar)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let requiresRowBackfill = cache.files.values.contains {
            $0.claudeRows == nil && !$0.days.isEmpty
        }
        let sourceInventoryChanged = priorMemo.map { $0.sourceInventory != sourceInventory } ?? false
        let cacheArtifactChanged = priorMemo.map {
            $0.reportKey.cacheArtifactStamp != cacheArtifactStamp
        } ?? false
        let scanConfigurationChanged = priorMemo.map {
            $0.reportKey.scanConfiguration != reportKey.scanConfiguration
        } ?? false
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || requiresRowBackfill
            || sourceInventoryChanged
            || cacheArtifactChanged
            || scanConfigurationChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs
        let providerFilter = options.claudeLogProviderFilter
        let hasStableProcessBaseline = priorMemo != nil
            && !sourceInventoryChanged
            && !cacheArtifactChanged
            && !scanConfigurationChanged
        let shouldMutateCache = shouldRefresh && (!hasStableProcessBaseline || options.forceRescan || windowExpanded)
        let pricingResolver = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: options.cacheRoot)

        if shouldMutateCache {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
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
                range: range,
                providerFilter: providerFilter,
                forceFullScan: options.forceRescan
                    || windowExpanded
                    || scanConfigurationChanged
                    || requiresRowBackfill,
                changedPaths: changedPaths,
                attributionResolver: attributionResolver,
                pricingResolver: pricingResolver,
                checkCancellation: checkCancellation)

            for path in inventory.files.keys.sorted() {
                guard let source = inventory.files[path] else { continue }
                try Self.processClaudeFile(
                    url: source.url,
                    size: source.stamp.size,
                    mtimeMs: source.stamp.mtimeUnixMs,
                    state: scanState)
            }
            try checkCancellation?()

            cache = scanState.cache
            cache.roots = nil

            for key in cache.files.keys where sourceInventory[key] == nil {
                cache.files.removeValue(forKey: key)
            }

            if let attributionResolver {
                Self.reconcileClaudeAttributions(
                    cache: &cache,
                    attributionResolver: attributionResolver,
                    modelsDevCatalog: pricingResolver.prepareCatalog(),
                    modelsDevCacheRoot: nil)
            }
            Self.rebuildClaudeDays(cache: &cache)
            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
        }

        var committedCacheStamp: CostUsageClaudeFileStamp?
        let report = try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: options.cacheRoot)
        {
            guard CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                stateRoot: options.cacheRoot) == cliProxyAPIConfigurationGeneration
            else { throw CancellationError() }
            guard CostUsageClaudeFileStamp.read(at: cliProxyUsageURL) == cliProxyUsageArtifactStamp
            else { throw CancellationError() }
            guard try Self.currentClaudeCLIProxyAPIInputArtifactFingerprint(
                options: options,
                attributionEnabled: cliProxyAPIAttributionEnabled,
                checkCancellation: checkCancellation) == cliProxyAPIInputArtifactFingerprint
            else { throw CancellationError() }

            let reportAttributionEnabled = !CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
                stateRoot: options.cacheRoot)
            if !reportAttributionEnabled {
                Self.removeCachedCLIProxyAPIAttribution(cache: &cache)
            }
            if shouldMutateCache {
                committedCacheStamp = try CostUsageClaudeCacheIO.save(
                    provider: provider,
                    cache: cache,
                    cacheRoot: options.cacheRoot,
                    calendar: range.calendar,
                    checkCancellation: checkCancellation)
            }
            let built = Self.buildClaudeReportFromCache(
                cache: cache,
                range: range,
                attributionFilter: options.claudeAttributionFilter,
                attributionResolver: reportAttributionEnabled ? attributionResolver : nil,
                allowCachedCLIProxyAPIAttribution: reportAttributionEnabled,
                pricingResolver: pricingResolver)
            try checkCancellation?()
            guard CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                stateRoot: options.cacheRoot) == cliProxyAPIConfigurationGeneration
            else { throw CancellationError() }
            guard try Self.currentClaudeCLIProxyAPIInputArtifactFingerprint(
                options: options,
                attributionEnabled: cliProxyAPIAttributionEnabled,
                checkCancellation: checkCancellation) == cliProxyAPIInputArtifactFingerprint
            else { throw CancellationError() }
            return built
        }

        let finalCacheArtifactStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        let finalPricingArtifactStamp = CostUsageClaudeFileStamp.read(at: pricingURL)
        let finalCLIProxyUsageArtifactStamp = CostUsageClaudeFileStamp.read(at: cliProxyUsageURL)
        let finalCLIProxyAPIInputArtifactFingerprint = try Self.currentClaudeCLIProxyAPIInputArtifactFingerprint(
            options: options,
            attributionEnabled: cliProxyAPIAttributionEnabled,
            checkCancellation: checkCancellation)
        let finalReportKey = Self.claudeReportMemoKey(
            provider: provider,
            providerFilter: providerFilter,
            attributionFilter: options.claudeAttributionFilter,
            cliProxyAPIConfigurationGeneration: cliProxyAPIConfigurationGeneration,
            cliProxyAPIAttributionEnabled: cliProxyAPIAttributionEnabled,
            cliProxyAPIInputArtifactFingerprint: finalCLIProxyAPIInputArtifactFingerprint,
            range: range,
            roots: roots,
            artifactStamps: (
                cache: finalCacheArtifactStamp,
                pricing: finalPricingArtifactStamp,
                proxyUsage: finalCLIProxyUsageArtifactStamp))
        let cacheArtifactIsCurrent = if shouldMutateCache {
            committedCacheStamp != nil && finalCacheArtifactStamp == committedCacheStamp
        } else {
            finalCacheArtifactStamp == cacheArtifactStamp
        }
        if cacheArtifactIsCurrent,
           finalPricingArtifactStamp == pricingArtifactStamp,
           finalCLIProxyUsageArtifactStamp == cliProxyUsageArtifactStamp,
           finalCLIProxyAPIInputArtifactFingerprint == cliProxyAPIInputArtifactFingerprint
        {
            memo.store(
                provider: provider,
                canonicalCachePath: canonicalCachePath,
                sourceInventory: sourceInventory,
                reportKey: finalReportKey,
                report: report)
        }
        return report
    }

    // swiftlint:disable:next function_parameter_count
    private static func claudeReportMemoKey(
        provider: UsageProvider,
        providerFilter: ClaudeLogProviderFilter,
        attributionFilter: ClaudeAttributionFilter,
        cliProxyAPIConfigurationGeneration: String?,
        cliProxyAPIAttributionEnabled: Bool,
        cliProxyAPIInputArtifactFingerprint: [String: CostUsageClaudeFileStamp]?,
        range: CostUsageDayRange,
        roots: [URL],
        artifactStamps: (
            cache: CostUsageClaudeFileStamp?,
            pricing: CostUsageClaudeFileStamp?,
            proxyUsage: CostUsageClaudeFileStamp?))
        -> CostUsageClaudeReportMemoKey
    {
        let providerFilterKey = switch providerFilter {
        case .all: "all"
        case .vertexAIOnly: "vertex-ai-only"
        case .excludeVertexAI: "exclude-vertex-ai"
        }
        let attributionFilterKey = switch attributionFilter {
        case .all: "all"
        case .codexBackendOnly: "codex-backend-only"
        case .excludeCodexBackend: "exclude-codex-backend"
        }
        return CostUsageClaudeReportMemoKey(
            provider: provider,
            providerFilter: providerFilterKey,
            attributionFilter: attributionFilterKey,
            cliProxyAPIConfigurationGeneration: cliProxyAPIConfigurationGeneration,
            cliProxyAPIAttributionEnabled: cliProxyAPIAttributionEnabled,
            sinceKey: range.sinceKey,
            untilKey: range.untilKey,
            scanSinceKey: range.scanSinceKey,
            scanUntilKey: range.scanUntilKey,
            timeZoneIdentifier: range.calendar.timeZone.identifier,
            roots: roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.sorted(),
            cacheArtifactStamp: artifactStamps.cache,
            pricingArtifactStamp: artifactStamps.pricing,
            cliProxyUsageArtifactStamp: artifactStamps.proxyUsage,
            cliProxyAPIInputArtifactFingerprint: cliProxyAPIInputArtifactFingerprint)
    }

    private struct ClaudeReportAggregation {
        var dayModels: [String: [ClaudeDayModelKey: [Int]]] = [:]
        var repricedCosts: [ClaudeDayModelKey: ClaudeRepricedCost] = [:]
    }

    private struct ClaudeAttributionAggregationContext {
        let filter: ClaudeAttributionFilter
        let resolver: CLIProxyAPIAttributionResolver?
        let allowCachedCLIProxyAPIAttribution: Bool
    }

    private static func aggregateClaudeRows(
        cache: CostUsageCache,
        attributionContext: ClaudeAttributionAggregationContext,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> ClaudeReportAggregation
    {
        var result = ClaudeReportAggregation()
        let rows = Self.reconciledClaudeRows(cache: cache)
        guard !rows.isEmpty else { return result }
        let modelsDevCatalog = pricingResolver.prepareCatalog()
        let rowsWithProviders = rows.map { row in
            let modelProvider = if row.attribution?.route == .cliProxyAPI,
                                   let cachedProvider = row.attribution?.modelProvider,
                                   cachedProvider != .unknown
            {
                cachedProvider
            } else {
                CostUsagePricing.modelProvider(
                    for: row.model,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: nil)
            }
            return (row: row, modelProvider: modelProvider)
        }
        let requests = rowsWithProviders.map { item in
            CLIProxyAPIAttributionResolver.Request(
                model: item.row.model,
                modelProvider: item.modelProvider,
                sessionID: item.row.sessionId,
                timestampUnixMs: item.row.timestampUnixMs,
                tokens: .init(
                    input: item.row.input,
                    cacheRead: item.row.cacheRead,
                    cacheCreate: item.row.cacheCreate,
                    output: item.row.output),
                occurrenceID: item.row.messageId)
        }
        let liveAttributions: [CostUsageAttribution?] = if let resolver = attributionContext.resolver {
            resolver.attributions(for: requests).map(Optional.some)
        } else {
            Array(repeating: nil, count: rowsWithProviders.count)
        }

        for (index, item) in rowsWithProviders.enumerated() {
            let row = item.row
            let request = requests[index]
            let liveAttribution = liveAttributions[index]
            let cachedAttribution: CostUsageAttribution? =
                if !attributionContext.allowCachedCLIProxyAPIAttribution,
                row.attribution?.route == .cliProxyAPI {
                    nil
                } else {
                    row.attribution
                }
            let attribution: CostUsageAttribution? = if let liveAttribution,
                                                        liveAttribution.route == .cliProxyAPI
            {
                Self.preferredCLIProxyAPIAttribution(live: liveAttribution, cached: cachedAttribution)
            } else if Self.shouldPreserveCachedCLIProxyAPIAttribution(
                row.attribution,
                allowCached: attributionContext.allowCachedCLIProxyAPIAttribution,
                hasMatchingObservation: attributionContext.resolver?.hasMatchingObservation(for: request) == true)
            {
                row.attribution
            } else if item.modelProvider != .anthropic {
                liveAttribution ?? cachedAttribution
            } else {
                nil
            }
            let isCodexBackend = attribution?.route == .cliProxyAPI && attribution?.upstream?.isCodex == true
            let isNonClaudeProxyBackend = attribution?.route == .cliProxyAPI &&
                attribution?.upstream?.isAnthropic != true
            let isUnresolvedAttribution = if attribution?.route == .cliProxyAPI {
                attribution?.upstream == nil
            } else {
                item.modelProvider != .anthropic && item.modelProvider != .unknown
            }
            let includeRow = switch attributionContext.filter {
            case .all: true
            case .codexBackendOnly: isCodexBackend
            case .excludeCodexBackend: !isCodexBackend && !isNonClaudeProxyBackend && !isUnresolvedAttribution
            }
            guard includeRow else { continue }

            #if DEBUG
            Self.recordClaudeScanWork(.reprice)
            #endif
            let key = ClaudeDayModelKey(day: row.dayKey, model: row.model, attribution: attribution)
            var models = result.dayModels[row.dayKey] ?? [:]
            var packed = models[key] ?? [0, 0, 0, 0, 0, 0]
            packed[0] += row.input
            packed[1] += row.cacheRead
            packed[2] += row.cacheCreate
            packed[3] += row.output
            packed[5] += 1
            models[key] = packed
            result.dayModels[row.dayKey] = models

            var repriced = result.repricedCosts[key] ?? ClaudeRepricedCost()
            repriced.sampleCount += 1
            let wasPriced = row.costPriced ?? (row.costNanos > 0)
            let upstreamModel = attribution?.route == .cliProxyAPI
                ? attribution?.upstream?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let pricingModel = upstreamModel.flatMap { $0.isEmpty ? nil : $0 } ?? row.model
            let cachedUpstreamModel = row.attribution?.route == .cliProxyAPI
                ? row.attribution?.upstream?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let cachedPricingModel = cachedUpstreamModel.flatMap { $0.isEmpty ? nil : $0 } ?? row.model
            let pricingProvider = CostUsagePricing.modelProvider(
                for: pricingModel,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: nil)
            let currentCost = Self.currentClaudeRowCost(
                row,
                pricingModel: pricingModel,
                pricingProvider: pricingProvider,
                pricingResolver: pricingResolver)
            let resolvedCost = Self.resolvedClaudeRowCost(
                wasPriced: wasPriced,
                cachedCostNanos: row.costNanos,
                cachedPricingModel: cachedPricingModel,
                pricingModel: pricingModel,
                currentCost: currentCost)
            if let resolvedCost {
                repriced.total += resolvedCost
            } else {
                repriced.unresolved = true
            }
            result.repricedCosts[key] = repriced
        }
        return result
    }

    static func shouldPreserveCachedCLIProxyAPIAttribution(
        _ cached: CostUsageAttribution?,
        allowCached: Bool,
        hasMatchingObservation: Bool) -> Bool
    {
        guard allowCached,
              let cached,
              cached.route == .cliProxyAPI
        else { return false }
        return !hasMatchingObservation || cached.evidence.contains(.cliProxyUsageTelemetry)
    }

    static func resolvedClaudeRowCost(
        wasPriced: Bool,
        cachedCostNanos: Int,
        cachedPricingModel: String,
        pricingModel: String,
        currentCost: Double?) -> Double?
    {
        let pricingModelUnchanged = cachedPricingModel.caseInsensitiveCompare(pricingModel) == .orderedSame
        if wasPriced, cachedCostNanos == 0, pricingModelUnchanged {
            return 0
        }
        if let currentCost {
            return currentCost
        }
        guard wasPriced, pricingModelUnchanged else { return nil }
        return Double(cachedCostNanos) / 1_000_000_000.0
    }

    private static func currentClaudeRowCost(
        _ row: ClaudeUsageRow,
        pricingModel: String,
        pricingProvider: CostUsageAttribution.ModelProvider,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> Double?
    {
        let modelsDevCatalog = pricingResolver.prepareCatalog()
        if pricingProvider == .openAI {
            return CostUsagePricing.claudeProxyCodexCostUSD(
                model: pricingModel,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreate,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: nil)
        }
        if pricingProvider == .google {
            return CostUsagePricing.claudeProxyGoogleCostUSD(
                model: pricingModel,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreate,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: nil)
        }
        guard pricingProvider == .anthropic || pricingProvider == .other || pricingProvider == .unknown
        else { return nil }
        return pricingResolver.costUSD(
            model: pricingModel,
            inputTokens: row.input,
            cacheReadInputTokens: row.cacheRead,
            cacheCreationInputTokens: row.cacheCreate,
            cacheCreationInputTokens1h: row.cacheCreate1h ?? 0,
            outputTokens: row.output,
            pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }

    static func buildClaudeReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        attributionFilter: ClaudeAttributionFilter = .all,
        attributionResolver: CLIProxyAPIAttributionResolver? = nil,
        allowCachedCLIProxyAPIAttribution: Bool = true,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> CostUsageDailyReport
    {
        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreate = 0
        var totalTokens = 0
        var totalCost: Double = 0
        var costSeen = false
        let aggregation = Self.aggregateClaudeRows(
            cache: cache,
            attributionContext: .init(
                filter: attributionFilter,
                resolver: attributionResolver,
                allowCachedCLIProxyAPIAttribution: allowCachedCLIProxyAPIAttribution),
            pricingResolver: pricingResolver)
        let dayModels = aggregation.dayModels
        let repricedCosts = aggregation.repricedCosts

        let dayKeys = dayModels.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        for day in dayKeys {
            guard let models = dayModels[day] else { continue }
            let modelKeys = models.keys.sorted {
                if $0.model != $1.model { return $0.model < $1.model }
                return ($0.attribution?.deterministicSortKey ?? "")
                    < ($1.attribution?.deterministicSortKey ?? "")
            }

            var dayInput = 0
            var dayOutput = 0
            var dayCacheRead = 0
            var dayCacheCreate = 0

            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for modelKey in modelKeys {
                let model = modelKey.model
                let packed = models[modelKey] ?? [0, 0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cacheRead = packed[safe: 1] ?? 0
                let cacheCreate = packed[safe: 2] ?? 0
                let output = packed[safe: 3] ?? 0
                let sampleCount = packed[safe: 5] ?? 0
                let totalTokens = input + cacheRead + cacheCreate + output

                // Cache tokens are tracked separately; totalTokens includes input + cache.
                dayInput += input
                dayCacheRead += cacheRead
                dayCacheCreate += cacheCreate
                dayOutput += output

                let repricedCost = repricedCosts[modelKey]
                let currentPricingCost: Double? = if let repricedCost,
                                                     repricedCost.sampleCount == sampleCount,
                                                     !repricedCost.unresolved
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
                        totalTokens: totalTokens,
                        requestCount: sampleCount,
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: cacheRead,
                        cacheCreationTokens: cacheCreate,
                        attribution: modelKey.attribution))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let sortedBreakdown = Self.sortedModelBreakdowns(breakdown)

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
                modelsUsed: Array(Set(modelKeys.map(\.model))).sorted(),
                modelBreakdowns: sortedBreakdown))

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

    static func buildClaudeReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        attributionFilter: ClaudeAttributionFilter = .all,
        attributionResolver: CLIProxyAPIAttributionResolver? = nil,
        allowCachedCLIProxyAPIAttribution: Bool = true,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> CostUsageDailyReport
    {
        let pricingResolver = modelsDevCatalog.map { CostUsagePricing.ClaudeResolver(catalog: $0) }
            ?? CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: modelsDevCacheRoot)
        return Self.buildClaudeReportFromCache(
            cache: cache,
            range: range,
            attributionFilter: attributionFilter,
            attributionResolver: attributionResolver,
            allowCachedCLIProxyAPIAttribution: allowCachedCLIProxyAPIAttribution,
            pricingResolver: pricingResolver)
    }
}
