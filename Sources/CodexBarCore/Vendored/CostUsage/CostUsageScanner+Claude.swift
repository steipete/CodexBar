import Foundation

extension CostUsageScanner {
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
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
    }

    private static func resolveClaudeModel(
        model: String,
        tokens: ClaudeRawTokens,
        context: ClaudeModelResolutionContext) -> ClaudeModelResolution
    {
        let modelProvider = CostUsagePricing.modelProvider(
            for: model,
            modelsDevCatalog: context.modelsDevCatalog,
            modelsDevCacheRoot: context.modelsDevCacheRoot)
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
        let attribution = resolvedAttribution.route == .cliProxyAPI || modelProvider != .anthropic
            ? resolvedAttribution
            : nil
        let upstreamModel = resolvedAttribution.route == .cliProxyAPI
            ? resolvedAttribution.upstream?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let pricingModel = upstreamModel.flatMap { $0.isEmpty ? nil : $0 } ?? model
        let pricingProvider = CostUsagePricing.modelProvider(
            for: pricingModel,
            modelsDevCatalog: context.modelsDevCatalog,
            modelsDevCacheRoot: context.modelsDevCacheRoot)
        let cost: Double? = if pricingProvider == .openAI {
            CostUsagePricing.claudeProxyCodexCostUSD(
                model: pricingModel,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                outputTokens: tokens.output,
                modelsDevCatalog: context.modelsDevCatalog,
                modelsDevCacheRoot: context.modelsDevCacheRoot)
        } else if pricingProvider == .anthropic {
            CostUsagePricing.claudeCostUSD(
                model: pricingModel,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                cacheCreationInputTokens1h: tokens.cacheCreate1h,
                outputTokens: tokens.output,
                pricingDate: context.pricingDate,
                modelsDevCatalog: context.modelsDevCatalog,
                modelsDevCacheRoot: context.modelsDevCacheRoot)
        } else if pricingProvider == .google {
            CostUsagePricing.claudeProxyGoogleCostUSD(
                model: pricingModel,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreate,
                outputTokens: tokens.output,
                modelsDevCatalog: context.modelsDevCatalog,
                modelsDevCacheRoot: context.modelsDevCacheRoot)
        } else { nil }
        let normalizedModel = switch modelProvider {
        case .openAI:
            CostUsagePricing.normalizeCodexModel(model)
        case .anthropic:
            CostUsagePricing.normalizeClaudeModel(model)
        case .google, .unknown:
            model.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        if let override = options.claudeProjectsRoots { return override }

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
        (
            try? self.parseClaudeFileCancellable(
                fileURL: fileURL,
                range: range,
                providerFilter: providerFilter,
                startOffset: startOffset,
                attributionResolver: attributionResolver,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot,
                checkCancellation: nil)) ?? ClaudeParseResult(days: [:], rows: [], parsedBytes: startOffset)
    }

    static func parseClaudeFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        attributionResolver: CLIProxyAPIAttributionResolver? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        checkCancellation: CancellationCheck? = nil) throws -> ClaudeParseResult
    {
        func add(dayKey: String, model: String, tokens: ClaudeTokens, days: inout [String: [String: [Int]]]) {
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
            else { return }
            let normModel = CostUsagePricing.normalizeClaudeModel(model)
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0, 0, 0, 0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + tokens.input
            packed[1] = (packed[safe: 1] ?? 0) + tokens.cacheRead
            packed[2] = (packed[safe: 2] ?? 0) + tokens.cacheCreate
            packed[3] = (packed[safe: 3] ?? 0) + tokens.output
            packed[4] = (packed[safe: 4] ?? 0) + tokens.costNanos
            packed[5] = (packed[safe: 5] ?? 0) + 1
            packed[6] = (packed[safe: 6] ?? 0) + (tokens.costPriced ? 1 : 0)
            packed[7] = (packed[safe: 7] ?? 0) + tokens.cacheCreate1h
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        func toInt(_ v: Any?) -> Int {
            if let n = v as? NSNumber { return n.intValue }
            return 0
        }

        func toBool(_ value: Any?) -> Bool {
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
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
                            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                            let type = obj["type"] as? String,
                            type == "assistant"
                        else { return }
                        guard Self.matchesClaudeProviderFilter(obj: obj, filter: providerFilter) else { return }

                        guard let tsText = obj["timestamp"] as? String, let timestamp = Self.dateFromTimestamp(tsText)
                        else { return }
                        guard let dayKey = Self.dayKeyFromTimestamp(tsText, calendar: range.calendar)
                            ?? Self.dayKeyFromParsedISO(tsText, calendar: range.calendar)
                        else { return }

                        guard let message = obj["message"] as? [String: Any] else { return }
                        guard let model = message["model"] as? String else { return }
                        guard let usage = message["usage"] as? [String: Any] else { return }

                        let input = max(0, toInt(usage["input_tokens"]))
                        let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
                        let cacheCreate1h = Self.claudeOneHourCacheCreationTokens(
                            usage: usage,
                            total: cacheCreate)
                        let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
                        let output = max(0, toInt(usage["output_tokens"]))
                        if input == 0, cacheCreate == 0, cacheRead == 0, output == 0 { return }

                        let rawTokens = ClaudeRawTokens(
                            input: input,
                            cacheRead: cacheRead,
                            cacheCreate: cacheCreate,
                            cacheCreate1h: cacheCreate1h,
                            output: output)
                        let sessionId = obj["sessionId"] as? String
                            ?? obj["session_id"] as? String
                            ?? (obj["metadata"] as? [String: Any])?["sessionId"] as? String
                            ?? (message["metadata"] as? [String: Any])?["sessionId"] as? String
                        let timestampUnixMs = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
                        let modelResolution = Self.resolveClaudeModel(
                            model: model,
                            tokens: rawTokens,
                            context: ClaudeModelResolutionContext(
                                pricingDate: timestamp,
                                sessionID: sessionId,
                                timestampUnixMs: timestampUnixMs,
                                attributionResolver: attributionResolver,
                                modelsDevCatalog: modelsDevCatalog,
                                modelsDevCacheRoot: modelsDevCacheRoot))
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
        var days: [String: [String: [Int]]] = [:]
        for row in rows {
            let tokens = ClaudeTokens(
                input: row.input,
                cacheRead: row.cacheRead,
                cacheCreate: row.cacheCreate,
                cacheCreate1h: row.cacheCreate1h ?? 0,
                output: row.output,
                costNanos: row.costNanos,
                costPriced: row.costPriced ?? (row.costNanos > 0))
            add(dayKey: row.dayKey, model: row.model, tokens: tokens, days: &days)
        }

        return ClaudeParseResult(days: days, rows: rows, parsedBytes: parsedBytes)
    }

    private static func claudeOneHourCacheCreationTokens(usage: [String: Any], total: Int) -> Int {
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else { return 0 }
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
                        output: row.output)),
                modelProvider: modelProvider,
                cachedAttribution: row.attribution)
        }
        let requests = items.map(\.request)
        let liveAttributions = attributionResolver.attributions(for: requests)
        var replacementKeys: Set<ClaudeAttributionReconciliationKey> = []
        var replacements: [ClaudeAttributionReconciliationKey: CostUsageAttribution] = [:]
        for (index, item) in items.enumerated()
            where attributionResolver.hasMatchingObservation(for: item.request)
        {
            replacementKeys.insert(item.key)
            let liveAttribution = liveAttributions[index]
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
        var touched: Set<String>
        let range: CostUsageDayRange
        let providerFilter: ClaudeLogProviderFilter
        let forceFullScan: Bool
        let attributionResolver: CLIProxyAPIAttributionResolver?
        let modelsDevCatalog: ModelsDevCatalog?
        let modelsDevCacheRoot: URL?
        let checkCancellation: CancellationCheck?

        init(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            providerFilter: ClaudeLogProviderFilter,
            forceFullScan: Bool,
            attributionResolver: CLIProxyAPIAttributionResolver?,
            modelsDevCatalog: ModelsDevCatalog?,
            modelsDevCacheRoot: URL?,
            checkCancellation: CancellationCheck?)
        {
            self.cache = cache
            self.touched = []
            self.range = range
            self.providerFilter = providerFilter
            self.forceFullScan = forceFullScan
            self.attributionResolver = attributionResolver
            self.modelsDevCatalog = modelsDevCatalog
            self.modelsDevCacheRoot = modelsDevCacheRoot
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
        state.touched.insert(path)

        if let cached = state.cache.files[path],
           cached.mtimeUnixMs == mtimeMs,
           cached.size == size,
           !state.forceFullScan
        {
            return
        }

        if let cached = state.cache.files[path], !state.forceFullScan {
            let startOffset = cached.parsedBytes ?? cached.size
            let canIncremental = size > cached.size && startOffset > 0 && startOffset <= size
                && cached.claudeRows != nil
            if canIncremental {
                let delta = try Self.parseClaudeFileCancellable(
                    fileURL: url,
                    range: state.range,
                    providerFilter: state.providerFilter,
                    startOffset: startOffset,
                    attributionResolver: state.attributionResolver,
                    modelsDevCatalog: state.modelsDevCatalog,
                    modelsDevCacheRoot: state.modelsDevCacheRoot,
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

        let parsed = try Self.parseClaudeFileCancellable(
            fileURL: url,
            range: state.range,
            providerFilter: state.providerFilter,
            attributionResolver: state.attributionResolver,
            modelsDevCatalog: state.modelsDevCatalog,
            modelsDevCacheRoot: state.modelsDevCacheRoot,
            checkCancellation: state.checkCancellation)
        let usage = Self.makeClaudeFileUsage(
            mtimeMs: mtimeMs,
            size: size,
            rows: parsed.rows,
            parsedBytes: parsed.parsedBytes)
        state.cache.files[path] = usage
    }

    private static func scanClaudeRoot(
        root: URL,
        state: ClaudeScanState) throws
    {
        try state.checkCancellation?()
        let rootPath = root.path
        let rootCandidates = Self.claudeRootCandidates(for: rootPath)
        let prefixes = Set(rootCandidates).map { path in
            path.hasSuffix("/") ? path : "\(path)/"
        }
        let rootExists = rootCandidates.contains { FileManager.default.fileExists(atPath: $0) }

        guard rootExists else {
            let stale = state.cache.files.keys.filter { path in
                prefixes.contains(where: { path.hasPrefix($0) })
            }
            for path in stale {
                state.cache.files.removeValue(forKey: path)
            }
            return
        }

        // Always enumerate the directory tree. The per-file mtime/size cache in
        // processClaudeFile already skips unchanged files, so the only cost here is
        // the directory walk itself. The previous root-mtime optimization skipped
        // enumeration entirely when the root directory mtime was unchanged, but on
        // POSIX systems a directory mtime only updates for direct child changes —
        // not for files created or modified inside subdirectories. This caused new
        // session logs to go undetected until the cache was manually cleared.
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
            try state.checkCancellation?()
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            if size <= 0 { continue }

            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let mtimeMs = Int64(mtime * 1000)
            try Self.processClaudeFile(
                url: url,
                size: size,
                mtimeMs: mtimeMs,
                state: state)
        }

        // Root mtime caching removed — see comment above.
    }

    private struct ClaudeCLIProxyAPIAttributionState {
        let configurationGeneration: String?
        let resolver: CLIProxyAPIAttributionResolver?
    }

    private static func captureClaudeCLIProxyAPIAttributionState(
        options: Options,
        checkCancellation: CancellationCheck?) throws -> ClaudeCLIProxyAPIAttributionState
    {
        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: options.cacheRoot)
        {
            let configurationGeneration = CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                stateRoot: options.cacheRoot)
            let attributionResolver: CLIProxyAPIAttributionResolver?
            if !CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(stateRoot: options.cacheRoot),
               let home = options.cliProxyAPIHome
            {
                let usageRecords = CLIProxyAPIUsageCacheIO.loadAssumingInterprocessLockHeld(
                    cacheRoot: options.cacheRoot)
                attributionResolver = try CLIProxyAPIAttributionResolver.load(
                    home: home,
                    cacheRoot: options.cacheRoot,
                    forceReload: options.forceRescan,
                    usageRecords: usageRecords,
                    checkCancellation: checkCancellation)
            } else {
                attributionResolver = nil
            }
            return ClaudeCLIProxyAPIAttributionState(
                configurationGeneration: configurationGeneration,
                resolver: attributionResolver)
        }
    }

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
        let cliProxyAPIConfigurationGeneration = cliProxyAPIAttributionState.configurationGeneration
        let attributionResolver = cliProxyAPIAttributionState.resolver
        var cache = CostUsageCacheIO.load(
            provider: provider,
            cacheRoot: options.cacheRoot,
            calendar: range.calendar)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let requiresRowBackfill = cache.files.values.contains {
            $0.claudeRows == nil && !$0.days.isEmpty
        }
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || requiresRowBackfill
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        let providerFilter = options.claudeLogProviderFilter

        var touched: Set<String> = []

        if shouldRefresh {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
            }
            let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: options.cacheRoot)
            let scanState = ClaudeScanState(
                cache: cache,
                range: range,
                providerFilter: providerFilter,
                forceFullScan: options.forceRescan
                    || windowExpanded
                    || requiresRowBackfill,
                attributionResolver: attributionResolver,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: options.cacheRoot,
                checkCancellation: checkCancellation)

            let roots = self.defaultClaudeProjectsRoots(options: options)
            for root in roots {
                try Self.scanClaudeRoot(
                    root: root,
                    state: scanState)
            }
            try checkCancellation?()

            cache = scanState.cache
            touched = scanState.touched
            cache.roots = nil

            for key in cache.files.keys where !touched.contains(key) {
                cache.files.removeValue(forKey: key)
            }

            if let attributionResolver {
                Self.reconcileClaudeAttributions(
                    cache: &cache,
                    attributionResolver: attributionResolver,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: options.cacheRoot)
            }
            Self.rebuildClaudeDays(cache: &cache)
            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                stateRoot: options.cacheRoot)
            {
                guard CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                    stateRoot: options.cacheRoot) == cliProxyAPIConfigurationGeneration
                else { throw CancellationError() }
                if CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
                    stateRoot: options.cacheRoot)
                {
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
                }
                CostUsageCacheIO.save(
                    provider: provider,
                    cache: cache,
                    cacheRoot: options.cacheRoot,
                    calendar: range.calendar)
            }
        }

        let modelsDevCatalog = CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: options.cacheRoot)
        return try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: options.cacheRoot)
        {
            guard CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                stateRoot: options.cacheRoot) == cliProxyAPIConfigurationGeneration
            else { throw CancellationError() }

            let reportAttributionEnabled = !CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
                stateRoot: options.cacheRoot)
            let reportAttributionFilter: ClaudeAttributionFilter = if reportAttributionEnabled {
                options.claudeAttributionFilter
            } else {
                switch options.claudeAttributionFilter {
                case .all, .excludeCodexBackend: .all
                case .codexBackendOnly: .codexBackendOnly
                }
            }
            let report = Self.buildClaudeReportFromCache(
                cache: cache,
                range: range,
                attributionFilter: reportAttributionFilter,
                attributionResolver: reportAttributionEnabled ? attributionResolver : nil,
                allowCachedCLIProxyAPIAttribution: reportAttributionEnabled,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: options.cacheRoot)
            try checkCancellation?()
            guard CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                stateRoot: options.cacheRoot) == cliProxyAPIConfigurationGeneration
            else { throw CancellationError() }
            return report
        }
    }

    private struct ClaudeReportAggregation {
        var dayModels: [String: [ClaudeDayModelKey: [Int]]] = [:]
        var repricedCosts: [ClaudeDayModelKey: ClaudeRepricedCost] = [:]
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

    private struct ClaudeAttributionAggregationContext {
        let filter: ClaudeAttributionFilter
        let resolver: CLIProxyAPIAttributionResolver?
        let allowCachedCLIProxyAPIAttribution: Bool
    }

    private static func aggregateClaudeRows(
        cache: CostUsageCache,
        attributionContext: ClaudeAttributionAggregationContext,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> ClaudeReportAggregation
    {
        var result = ClaudeReportAggregation()
        let rowsWithProviders = Self.reconciledClaudeRows(cache: cache).map { row in
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
                    output: item.row.output))
        }
        let liveAttributions: [CostUsageAttribution?] = if let attributionResolver = attributionContext.resolver {
            attributionResolver.attributions(for: requests).map(Optional.some)
        } else {
            Array(repeating: nil, count: rowsWithProviders.count)
        }

        for (index, item) in rowsWithProviders.enumerated() {
            let row = item.row
            let modelProvider = item.modelProvider
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
                Self.preferredCLIProxyAPIAttribution(
                    live: liveAttribution,
                    cached: cachedAttribution)
            } else if attributionContext.allowCachedCLIProxyAPIAttribution,
                      row.attribution?.route == .cliProxyAPI,
                      attributionContext.resolver?.hasMatchingObservation(for: request) != true
            {
                row.attribution
            } else if modelProvider != .anthropic {
                liveAttribution ?? cachedAttribution
            } else {
                nil
            }
            let isCodexBackend = attribution?.route == .cliProxyAPI
                && attribution?.upstream?.isCodex == true
            let isUnresolvedAttribution = if attribution?.route == .cliProxyAPI {
                attribution?.upstream == nil
            } else {
                modelProvider != .anthropic && modelProvider != .unknown
            }
            let includeRow = switch attributionContext.filter {
            case .all: true
            case .codexBackendOnly: isCodexBackend
            case .excludeCodexBackend: !isCodexBackend && !isUnresolvedAttribution
            }
            guard includeRow else { continue }

            var models = result.dayModels[row.dayKey] ?? [:]
            let key = ClaudeDayModelKey(
                day: row.dayKey,
                model: row.model,
                attribution: attribution)
            var packed = models[key] ?? [0, 0, 0, 0, 0, 0]
            packed[0] += row.input
            packed[1] += row.cacheRead
            packed[2] += row.cacheCreate
            packed[3] += row.output
            packed[5] += 1
            models[key] = packed
            result.dayModels[row.dayKey] = models

            var cost = result.repricedCosts[key] ?? ClaudeRepricedCost()
            cost.sampleCount += 1
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
                modelsDevCacheRoot: modelsDevCacheRoot)
            let currentCost = Self.currentClaudeRowCost(
                row,
                pricingModel: pricingModel,
                pricingProvider: pricingProvider,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            let resolvedCost = Self.resolvedClaudeRowCost(
                wasPriced: wasPriced,
                cachedCostNanos: row.costNanos,
                cachedPricingModel: cachedPricingModel,
                pricingModel: pricingModel,
                currentCost: currentCost)
            if let resolvedCost {
                cost.total += resolvedCost
            } else {
                cost.unresolved = true
            }
            result.repricedCosts[key] = cost
        }
        return result
    }

    static func preferredCLIProxyAPIAttribution(
        live: CostUsageAttribution,
        cached: CostUsageAttribution?) -> CostUsageAttribution
    {
        guard live.route == .cliProxyAPI,
              live.upstream == nil,
              let cached,
              cached.route == .cliProxyAPI,
              cached.upstream != nil,
              cached.evidence.contains(.cliProxyUsageTelemetry)
        else { return live }
        return cached
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
        return Double(cachedCostNanos) / Self.costScale
    }

    private static func currentClaudeRowCost(
        _ row: ClaudeUsageRow,
        pricingModel: String,
        pricingProvider: CostUsageAttribution.ModelProvider,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> Double?
    {
        if pricingProvider == .openAI {
            return CostUsagePricing.claudeProxyCodexCostUSD(
                model: pricingModel,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreate,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
        }
        if pricingProvider == .google {
            return CostUsagePricing.claudeProxyGoogleCostUSD(
                model: pricingModel,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreate,
                outputTokens: row.output,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
        }
        guard pricingProvider == .anthropic else { return nil }
        return CostUsagePricing.claudeCostUSD(
            model: pricingModel,
            inputTokens: row.input,
            cacheReadInputTokens: row.cacheRead,
            cacheCreationInputTokens: row.cacheCreate,
            cacheCreationInputTokens1h: row.cacheCreate1h ?? 0,
            outputTokens: row.output,
            pricingDate: row.timestampUnixMs.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            },
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
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
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        let dayModels = aggregation.dayModels
        let repricedCosts = aggregation.repricedCosts

        let dayKeys = dayModels.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        for day in dayKeys {
            guard let models = dayModels[day] else { continue }
            let modelKeys = models.keys.sorted {
                if $0.model != $1.model { return $0.model < $1.model }
                return ($0.attribution?.upstream?.provider ?? "") < ($1.attribution?.upstream?.provider ?? "")
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
}
