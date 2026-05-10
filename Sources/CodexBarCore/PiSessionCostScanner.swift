import Foundation

enum PiSessionCostScanner {
    struct Options {
        var piSessionsRoot: URL?
        var cacheRoot: URL?
        var refreshMinIntervalSeconds: TimeInterval = 60
        var forceRescan: Bool = false

        init(
            piSessionsRoot: URL? = nil,
            cacheRoot: URL? = nil,
            refreshMinIntervalSeconds: TimeInterval = 60,
            forceRescan: Bool = false)
        {
            self.piSessionsRoot = piSessionsRoot
            self.cacheRoot = cacheRoot
            self.refreshMinIntervalSeconds = refreshMinIntervalSeconds
            self.forceRescan = forceRescan
        }
    }

    private struct ParseResult {
        let contributions: [String: [String: [String: PiPackedUsage]]]
        let parsedBytes: Int64
        let lastModelContext: PiModelContext?
    }

    private struct AssistantIdentity {
        let provider: UsageProvider
        let modelName: String
    }

    private struct ModelsDevPricingContext {
        let catalog: ModelsDevCatalog?
        let cacheRoot: URL?
    }

    private static let costScale = 1_000_000_000.0
    private static let maxLineBytes = 16 * 1024 * 1024
    private static let maxSafeRoundedInt = Double(Int.max) - 1

    static func loadDailyReport(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options()) -> CostUsageDailyReport
    {
        guard provider == .codex || provider == .claude else {
            return CostUsageDailyReport(data: [], summary: nil)
        }

        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until)
        var cache = PiSessionCostCacheIO.load(cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let pricingContext = ModelsDevPricingContext(
            catalog: CostUsagePricing.modelsDevCatalog(now: now, cacheRoot: options.cacheRoot),
            cacheRoot: options.cacheRoot)
        let windowExpanded = self.requestedWindowExpandsCache(range: range, cache: cache)
        let shouldRefresh = options.forceRescan
            || windowExpanded
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs

        if shouldRefresh {
            let root = self.defaultPiSessionsRoot(options: options)
            let startCutoff = self.dateFromDayKey(range.scanSinceKey) ?? since
            let files = self.listPiSessionFiles(root: root, startCutoffLocal: startCutoff)
            let filePathsInScan = Set(files.map(\.path))

            for fileURL in files {
                self.scanPiSessionFile(
                    fileURL: fileURL,
                    range: range,
                    forceRescan: options.forceRescan || windowExpanded,
                    pricingContext: pricingContext,
                    cache: &cache)
            }

            for key in cache.files.keys where !filePathsInScan.contains(key) {
                if let old = cache.files[key] {
                    self.applyContributions(
                        daysByProvider: &cache.daysByProvider,
                        contributions: old.contributions,
                        sign: -1)
                }
                cache.files.removeValue(forKey: key)
            }

            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
            PiSessionCostCacheIO.save(cache: cache, cacheRoot: options.cacheRoot)
        }

        return self.buildReport(
            provider: provider,
            cache: cache,
            range: range,
            pricingContext: pricingContext)
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

    private static func defaultPiSessionsRoot(options: Options) -> URL {
        if let override = options.piSessionsRoot { return override }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func listPiSessionFiles(root: URL, startCutoffLocal: Date) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        var output: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try? item.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }

            let startedAt = self.parseSessionStartFromFilename(item.lastPathComponent)
            let modifiedAt = values?.contentModificationDate
            if self
                .shouldIncludeFile(startedAt: startedAt, modifiedAt: modifiedAt, startCutoffLocal: startCutoffLocal)
            {
                output.append(item)
            }
        }

        return output.sorted(by: { $0.path < $1.path })
    }

    private static func shouldIncludeFile(
        startedAt: Date?,
        modifiedAt: Date?,
        startCutoffLocal: Date) -> Bool
    {
        if let modifiedAt, self.localMidnight(modifiedAt) >= startCutoffLocal {
            return true
        }
        if let startedAt, self.localMidnight(startedAt) >= startCutoffLocal {
            return true
        }
        return false
    }

    private static func scanPiSessionFile(
        fileURL: URL,
        range: CostUsageScanner.CostUsageDayRange,
        forceRescan: Bool,
        pricingContext: ModelsDevPricingContext,
        cache: inout PiSessionCostCache)
    {
        let path = fileURL.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtimeMs = Int64(mtime * 1000)

        func storeFileUsage(_ usage: PiSessionFileUsage) {
            cache.files[path] = usage
        }

        let cached = cache.files[path]
        if !forceRescan,
           let cached,
           cached.mtimeUnixMs == mtimeMs,
           cached.size == size
        {
            return
        }

        if !forceRescan,
           let cached,
           size > cached.size,
           cached.parsedBytes > 0,
           cached.parsedBytes <= size
        {
            let delta = self.parsePiSessionFile(
                fileURL: fileURL,
                range: range,
                startOffset: cached.parsedBytes,
                initialModelContext: cached.lastModelContext,
                pricingContext: pricingContext)
            if !delta.contributions.isEmpty {
                self.applyContributions(
                    daysByProvider: &cache.daysByProvider,
                    contributions: delta.contributions,
                    sign: 1)
            }
            let merged = self.mergedContributions(existing: cached.contributions, delta: delta.contributions)
            storeFileUsage(PiSessionFileUsage(
                mtimeUnixMs: mtimeMs,
                size: size,
                parsedBytes: delta.parsedBytes,
                lastModelContext: delta.lastModelContext,
                contributions: merged))
            return
        }

        if let cached {
            self.applyContributions(
                daysByProvider: &cache.daysByProvider,
                contributions: cached.contributions,
                sign: -1)
        }

        let parsed = self.parsePiSessionFile(
            fileURL: fileURL,
            range: range,
            pricingContext: pricingContext)
        if !parsed.contributions.isEmpty {
            self.applyContributions(daysByProvider: &cache.daysByProvider, contributions: parsed.contributions, sign: 1)
        }

        storeFileUsage(PiSessionFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            parsedBytes: parsed.parsedBytes,
            lastModelContext: parsed.lastModelContext,
            contributions: parsed.contributions))
    }

    private static func parsePiSessionFile(
        fileURL: URL,
        range: CostUsageScanner.CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModelContext: PiModelContext? = nil,
        pricingContext: ModelsDevPricingContext? = nil) -> ParseResult
    {
        var currentModelContext = initialModelContext
        var contributions: [String: [String: [String: PiPackedUsage]]] = [:]

        func add(provider: UsageProvider, dayKey: String, modelName: String, usage: PiPackedUsage) {
            guard !usage.isZero else { return }
            guard CostUsageScanner.CostUsageDayRange.isInRange(
                dayKey: dayKey,
                since: range.scanSinceKey,
                until: range.scanUntilKey)
            else {
                return
            }

            let providerKey = provider.rawValue
            var providerDays = contributions[providerKey] ?? [:]
            var dayModels = providerDays[dayKey] ?? [:]
            let merged = self.addPacked(a: dayModels[modelName] ?? PiPackedUsage(), b: usage, sign: 1)
            if merged.isZero {
                dayModels.removeValue(forKey: modelName)
            } else {
                dayModels[modelName] = merged
            }
            if dayModels.isEmpty {
                providerDays.removeValue(forKey: dayKey)
            } else {
                providerDays[dayKey] = dayModels
            }
            if providerDays.isEmpty {
                contributions.removeValue(forKey: providerKey)
            } else {
                contributions[providerKey] = providerDays
            }
        }

        let parsedBytes = (try? CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: startOffset,
            maxLineBytes: Self.maxLineBytes,
            prefixBytes: Self.maxLineBytes,
            onLine: { line in
                guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                autoreleasepool {
                    guard let object = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any]
                    else { return }
                    guard let type = object["type"] as? String else { return }

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
                    guard let identity else { return }
                    guard let date = self.timestampDate(entry: object, message: message) else { return }
                    let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: date)
                    let usage = self.extractUsage(
                        provider: identity.provider,
                        modelName: identity.modelName,
                        message: message,
                        pricingContext: pricingContext)
                    add(provider: identity.provider, dayKey: dayKey, modelName: identity.modelName, usage: usage)
                }
            })) ?? startOffset

        return ParseResult(
            contributions: contributions,
            parsedBytes: parsedBytes,
            lastModelContext: currentModelContext)
    }

    private static func modelContext(from object: [String: Any]) -> PiModelContext? {
        guard let providerText = object["provider"] as? String,
              let provider = self.mappedProvider(fromPiProvider: providerText)
        else {
            return nil
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
        pricingContext: ModelsDevPricingContext? = nil) -> PiPackedUsage
    {
        let usage = (message["usage"] as? [String: Any]) ?? [:]
        let input = self.readNonNegativeInt(
            usage["input"]
                ?? usage["inputTokens"]
                ?? usage["input_tokens"]
                ?? usage["promptTokens"]
                ?? usage["prompt_tokens"])
        let cacheRead = self.readNonNegativeInt(
            usage["cacheRead"]
                ?? usage["cacheReadTokens"]
                ?? usage["cache_read"]
                ?? usage["cache_read_tokens"]
                ?? usage["cacheReadInputTokens"]
                ?? usage["cache_read_input_tokens"])
        let cacheWrite = self.readNonNegativeInt(
            usage["cacheWrite"]
                ?? usage["cacheWriteTokens"]
                ?? usage["cache_write"]
                ?? usage["cache_write_tokens"]
                ?? usage["cacheCreationTokens"]
                ?? usage["cache_creation_tokens"]
                ?? usage["cacheCreationInputTokens"]
                ?? usage["cache_creation_input_tokens"])
        let output = self.readNonNegativeInt(
            usage["output"]
                ?? usage["outputTokens"]
                ?? usage["output_tokens"]
                ?? usage["completionTokens"]
                ?? usage["completion_tokens"])

        let directTotal = self.readNonNegativeInt(
            usage["totalTokens"]
                ?? usage["total_tokens"]
                ?? usage["tokenCount"]
                ?? usage["token_count"]
                ?? usage["tokens"])
        let derivedTotal = input + cacheRead + cacheWrite + output
        let totalTokens = max(directTotal, derivedTotal)

        let rawUsage = PiPackedUsage(
            inputTokens: input,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            outputTokens: output,
            totalTokens: totalTokens)
        let costUSD = self.computedCostUSD(
            provider: provider,
            modelName: modelName,
            usage: rawUsage,
            pricingContext: pricingContext)
        let costNanos = costUSD.map { Int64(($0 * self.costScale).rounded()) } ?? 0

        return PiPackedUsage(
            inputTokens: rawUsage.inputTokens,
            cacheReadTokens: rawUsage.cacheReadTokens,
            cacheWriteTokens: rawUsage.cacheWriteTokens,
            outputTokens: rawUsage.outputTokens,
            totalTokens: rawUsage.totalTokens,
            costNanos: costNanos,
            costSampleCount: costUSD == nil ? 0 : 1,
            usageSampleCount: 1)
    }

    private static func computedCostUSD(
        provider: UsageProvider,
        modelName: String,
        usage: PiPackedUsage,
        pricingContext: ModelsDevPricingContext? = nil) -> Double?
    {
        switch provider {
        case .codex:
            CostUsagePricing.codexCostUSD(
                model: modelName,
                inputTokens: usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens,
                cachedInputTokens: usage.cacheReadTokens,
                outputTokens: usage.outputTokens,
                modelsDevCatalog: pricingContext?.catalog,
                modelsDevCacheRoot: pricingContext?.cacheRoot)
        case .claude:
            CostUsagePricing.claudeCostUSD(
                model: modelName,
                inputTokens: usage.inputTokens,
                cacheReadInputTokens: usage.cacheReadTokens,
                cacheCreationInputTokens: usage.cacheWriteTokens,
                outputTokens: usage.outputTokens,
                modelsDevCatalog: pricingContext?.catalog,
                modelsDevCacheRoot: pricingContext?.cacheRoot)
        default:
            nil
        }
    }

    private static func readNonNegativeInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            let numeric = number.doubleValue
            guard numeric.isFinite, numeric >= 0, numeric <= self.maxSafeRoundedInt else { return 0 }
            return Int(numeric.rounded())
        }
        if let string = value as? String,
           let numeric = Double(string),
           numeric.isFinite,
           numeric >= 0,
           numeric <= self.maxSafeRoundedInt
        {
            return Int(numeric.rounded())
        }
        return 0
    }

    private static func mappedProvider(fromPiProvider provider: String) -> UsageProvider? {
        switch provider.lowercased() {
        case "openai-codex":
            .codex
        case "anthropic":
            .claude
        default:
            nil
        }
    }

    private static func buildReport(
        provider: UsageProvider,
        cache: PiSessionCostCache,
        range: CostUsageScanner.CostUsageDayRange,
        pricingContext: ModelsDevPricingContext? = nil) -> CostUsageDailyReport
    {
        guard let providerDays = cache.daysByProvider[provider.rawValue] else {
            return CostUsageDailyReport(data: [], summary: nil)
        }

        let dayKeys = providerDays.keys.sorted().filter {
            CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }

        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalTokens = 0
        var totalCostNanos: Int64 = 0
        var totalCostSamples = 0

        for dayKey in dayKeys {
            guard let models = providerDays[dayKey] else { continue }
            let modelNames = models.keys.sorted()

            var dayInput = 0
            var dayOutput = 0
            var dayCacheRead = 0
            var dayCacheWrite = 0
            var dayTotalTokens = 0
            var dayCostNanos: Int64 = 0
            var dayCostSamples = 0
            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []

            for modelName in modelNames {
                let packed = models[modelName] ?? PiPackedUsage()
                let modelTotalTokens = max(
                    packed.totalTokens,
                    packed.inputTokens + packed.cacheReadTokens + packed.cacheWriteTokens + packed.outputTokens)
                let currentPricingCost = self.computedCostUSD(
                    provider: provider,
                    modelName: modelName,
                    usage: packed,
                    pricingContext: pricingContext)
                let usageSampleCount = packed.usageSampleCount
                let hasCompleteCachedCost = (usageSampleCount ?? 0) > 0
                    && packed.costSampleCount == usageSampleCount
                // Cached costs are accumulated per message, which preserves Claude long-context threshold boundaries.
                let costNanos = hasCompleteCachedCost
                    ? packed.costNanos
                    : currentPricingCost.map { Int64(($0 * self.costScale).rounded()) }
                breakdown.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: modelName,
                    costUSD: costNanos.map { Double($0) / Self.costScale },
                    totalTokens: modelTotalTokens > 0 ? modelTotalTokens : nil))
                dayInput += packed.inputTokens
                dayOutput += packed.outputTokens
                dayCacheRead += packed.cacheReadTokens
                dayCacheWrite += packed.cacheWriteTokens
                dayTotalTokens += modelTotalTokens
                if let costNanos {
                    dayCostNanos += costNanos
                    dayCostSamples += 1
                }
            }

            let sortedBreakdown = self.sortedModelBreakdowns(breakdown)
            entries.append(CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: dayInput > 0 ? dayInput : nil,
                outputTokens: dayOutput > 0 ? dayOutput : nil,
                cacheReadTokens: dayCacheRead > 0 ? dayCacheRead : nil,
                cacheCreationTokens: dayCacheWrite > 0 ? dayCacheWrite : nil,
                totalTokens: dayTotalTokens > 0 ? dayTotalTokens : nil,
                costUSD: dayCostSamples > 0 ? Double(dayCostNanos) / Self.costScale : nil,
                modelsUsed: modelNames,
                modelBreakdowns: sortedBreakdown))

            totalInput += dayInput
            totalOutput += dayOutput
            totalCacheRead += dayCacheRead
            totalCacheWrite += dayCacheWrite
            totalTokens += dayTotalTokens
            totalCostNanos += dayCostNanos
            totalCostSamples += dayCostSamples
        }

        guard !entries.isEmpty else { return CostUsageDailyReport(data: [], summary: nil) }
        return CostUsageDailyReport(
            data: entries,
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: totalInput > 0 ? totalInput : nil,
                totalOutputTokens: totalOutput > 0 ? totalOutput : nil,
                cacheReadTokens: totalCacheRead > 0 ? totalCacheRead : nil,
                cacheCreationTokens: totalCacheWrite > 0 ? totalCacheWrite : nil,
                totalTokens: totalTokens > 0 ? totalTokens : nil,
                totalCostUSD: totalCostSamples > 0 ? Double(totalCostNanos) / Self.costScale : nil))
    }

    private static func mergedContributions(
        existing: [String: [String: [String: PiPackedUsage]]],
        delta: [String: [String: [String: PiPackedUsage]]]) -> [String: [String: [String: PiPackedUsage]]]
    {
        var merged = existing
        self.applyContributions(daysByProvider: &merged, contributions: delta, sign: 1)
        return merged
    }

    private static func applyContributions(
        daysByProvider: inout [String: [String: [String: PiPackedUsage]]],
        contributions: [String: [String: [String: PiPackedUsage]]],
        sign: Int)
    {
        for (providerKey, providerDays) in contributions {
            var mergedProviderDays = daysByProvider[providerKey] ?? [:]
            for (dayKey, dayModels) in providerDays {
                var mergedDayModels = mergedProviderDays[dayKey] ?? [:]
                for (modelName, packed) in dayModels {
                    let updated = self.addPacked(
                        a: mergedDayModels[modelName] ?? PiPackedUsage(),
                        b: packed,
                        sign: sign)
                    if updated.isZero {
                        mergedDayModels.removeValue(forKey: modelName)
                    } else {
                        mergedDayModels[modelName] = updated
                    }
                }
                if mergedDayModels.isEmpty {
                    mergedProviderDays.removeValue(forKey: dayKey)
                } else {
                    mergedProviderDays[dayKey] = mergedDayModels
                }
            }
            if mergedProviderDays.isEmpty {
                daysByProvider.removeValue(forKey: providerKey)
            } else {
                daysByProvider[providerKey] = mergedProviderDays
            }
        }
    }

    private static func addPacked(a: PiPackedUsage, b: PiPackedUsage, sign: Int) -> PiPackedUsage {
        let aUsageSampleCount = a.usageSampleCount ?? (a.isZero ? 0 : nil)
        let bUsageSampleCount = b.usageSampleCount ?? (b.isZero ? 0 : nil)
        let usageSampleCount: Int? = if let aCount = aUsageSampleCount, let bCount = bUsageSampleCount {
            max(0, aCount + sign * bCount)
        } else {
            nil
        }

        return PiPackedUsage(
            inputTokens: max(0, a.inputTokens + sign * b.inputTokens),
            cacheReadTokens: max(0, a.cacheReadTokens + sign * b.cacheReadTokens),
            cacheWriteTokens: max(0, a.cacheWriteTokens + sign * b.cacheWriteTokens),
            outputTokens: max(0, a.outputTokens + sign * b.outputTokens),
            totalTokens: max(0, a.totalTokens + sign * b.totalTokens),
            costNanos: max(0, a.costNanos + Int64(sign) * b.costNanos),
            costSampleCount: max(0, a.costSampleCount + sign * b.costSampleCount),
            usageSampleCount: usageSampleCount)
    }

    private static func parseSessionStartFromFilename(_ filename: String) -> Date? {
        let pattern = "^(\\d{4}-\\d{2}-\\d{2})T(\\d{2})-(\\d{2})-(\\d{2})-(\\d{3})Z_"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func localMidnight(_ date: Date) -> Date {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return Calendar.current.date(from: components) ?? date
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }

        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        return components.date
    }

    private static func sortedModelBreakdowns(_ breakdowns: [CostUsageDailyReport.ModelBreakdown])
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
}
