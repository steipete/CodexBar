import Foundation

enum AntigravityLocalReader {
    enum Coverage: Sendable {
        case complete
        case partial
        case unavailable
    }

    struct DailyReportResult: Sendable {
        let report: CostUsageDailyReport
        let coverage: Coverage
        let statistics: Statistics

        var isComplete: Bool {
            self.coverage == .complete
        }

        var isAvailable: Bool {
            self.coverage == .complete
        }
    }

    struct Event: Equatable {
        let session: String
        let row: Int64
        let turn: AntigravityProtoReader.ParsedTurn
        let cacheWrite: Int
        let input: Int
        let total: Int

        init?(session: String, row: Int64, turn: AntigravityProtoReader.ParsedTurn, cacheWrite: Int) {
            guard let usage = turn.usage, turn.timestampMs != nil,
                  let input = AntigravityLocalReader.checkedAdd(usage.systemPrompt, usage.newInput),
                  let total = AntigravityLocalReader.checkedSum(
                      [input, usage.output, usage.cacheRead, cacheWrite, usage.reasoning])
            else { return nil }
            self.session = session
            self.row = row
            self.turn = turn
            self.cacheWrite = cacheWrite
            self.input = input
            self.total = total
        }
    }

    struct SourceResult {
        var events: [Event] = []
        var isComplete = true
    }

    private struct RowIdentity: Hashable {
        let session: String
        let row: Int64
    }

    private struct ResponseIdentity: Hashable {
        let session: String
        let response: String
    }

    private struct LabelIdentity: Hashable {
        let session: String
        let label: String
    }

    static func normalizeModelID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            guard let next = self.checkedAdd(total, value) else { return nil }
            total = next
        }
        return total
    }

    static func makeDailyReportWithStatus(
        context: Context,
        calendar: Calendar = .current,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        now: Date = Date(),
        limits: Limits = Limits(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> DailyReportResult
    {
        let budget = Budget(limits: limits, clock: clock, cancellation: checkCancellation)
        // Codex-mirror estimates: public API prices applied to local token buckets.
        // No models.dev catalog match means no price; entries stay cost-less and tokens are unaffected.
        let pricingResolver = modelsDevCatalog.map { CostUsagePricing.AntigravityResolver(catalog: $0) }
            ?? CostUsagePricing.AntigravityResolver(now: now, cacheRoot: modelsDevCacheRoot)
        do {
            let databases = try self.discover(roots: context.databaseRoots, extension: "db", budget: budget)
            // A discovery error is not absence and never authorizes a cache replacement.
            if !databases.paths.isEmpty || !databases.isComplete {
                let source = try self.readDatabases(databases.paths, budget: budget)
                return try self.aggregate(
                    source,
                    discoveryComplete: databases.isComplete,
                    calendar: calendar,
                    pricingResolver: pricingResolver,
                    budget: budget)
            }
            let cache = try self.discover(roots: [context.cacheRoot], extension: "jsonl", budget: budget)
            guard !cache.paths.isEmpty || !cache.isComplete else {
                return DailyReportResult(
                    report: .init(data: [], summary: nil), coverage: .unavailable, statistics: budget.statistics)
            }
            let source = try self.readJSONL(cache.paths, budget: budget)
            return try self.aggregate(
                source,
                discoveryComplete: cache.isComplete,
                calendar: calendar,
                pricingResolver: pricingResolver,
                budget: budget)
        } catch ScanFailure.exhausted {
            return DailyReportResult(
                report: .init(data: [], summary: nil), coverage: .partial, statistics: budget.statistics)
        }
    }

    private static func aggregate(
        _ source: SourceResult,
        discoveryComplete: Bool,
        calendar: Calendar,
        pricingResolver: CostUsagePricing.AntigravityResolver? = nil,
        budget: Budget) throws -> DailyReportResult
    {
        var isComplete = discoveryComplete && source.isComplete
            && budget.statistics.sqliteHandlesOpened == budget.statistics.sqliteHandlesClosed
        var models: [LabelIdentity: String] = [:]
        var conflicts = Set<LabelIdentity>()
        for event in source.events {
            try budget.check()
            if let label = event.turn.label, let model = event.turn.model {
                let key = LabelIdentity(session: event.session, label: label)
                if let prior = models[key], prior != model {
                    conflicts.insert(key)
                } else {
                    models[key] = model
                }
            }
        }

        var rows: [RowIdentity: Event] = [:]
        var responses: [ResponseIdentity: Event] = [:]
        var entries: [String: CostUsageDailyReport.Entry] = [:]
        for event in source.events {
            try budget.check()
            let row = RowIdentity(session: event.session, row: event.row)
            guard let entry = self.entry(
                event,
                models: models,
                conflicts: conflicts,
                calendar: calendar,
                pricingResolver: pricingResolver)
            else {
                isComplete = false
                continue
            }
            if let prior = rows[row] {
                // Same filename/session and idx identifies a copied SQLite row, not its token payload.
                if prior != event { isComplete = false }
                continue
            }
            let response = event.turn.usage?.responseID.map {
                ResponseIdentity(session: event.session, response: $0)
            }
            if let response, let prior = responses[response] {
                if prior.turn != event.turn || prior.cacheWrite != event.cacheWrite {
                    isComplete = false
                } else {
                    rows[row] = event
                }
                continue
            }
            let next: CostUsageDailyReport.Entry
            if let prior = entries[entry.date] {
                guard let merged = self.checkedMergeEntry(prior, entry) else {
                    isComplete = false
                    continue
                }
                next = merged
            } else {
                next = entry
            }
            entries[entry.date] = next
            // Failed validation or aggregation must never reserve identity.
            rows[row] = event
            if let response { responses[response] = event }
        }
        let daily = entries.values.sorted { $0.date < $1.date }
        let total = self.checkedSum(daily.compactMap(\.totalTokens))
        let dailyCosts = daily.compactMap(\.costUSD)
        let totalCost: Double? = {
            guard !dailyCosts.isEmpty else { return nil }
            let sum = dailyCosts.reduce(0, +)
            return sum.isFinite ? sum : nil
        }()
        return DailyReportResult(
            report: .init(
                data: daily,
                summary: daily.isEmpty ? nil : .init(
                    totalInputTokens: nil,
                    totalOutputTokens: nil,
                    totalTokens: total,
                    totalCostUSD: totalCost)),
            coverage: isComplete ? .complete : .partial,
            statistics: budget.statistics)
    }

    private static func entry(
        _ event: Event,
        models: [LabelIdentity: String],
        conflicts: Set<LabelIdentity>,
        calendar: Calendar,
        pricingResolver: CostUsagePricing.AntigravityResolver? = nil) -> CostUsageDailyReport.Entry?
    {
        guard let usage = event.turn.usage, let timestamp = event.turn.timestampMs
        else { return nil }
        let input = event.input
        let total = event.total
        let label = event.turn.label.map { LabelIdentity(session: event.session, label: $0) }
        let inherited = label.flatMap { conflicts.contains($0) ? nil : models[$0] }
        let model = self.normalizeModelID(event.turn.model ?? inherited ?? "unknown")
        let eventDate = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let day = CostUsageLocalDay.key(from: eventDate, calendar: calendar)
        // Thinking tokens bill at output rates, matching the provider's API pricing.
        let costUSD = pricingResolver?.costUSD(
            model: model,
            inputTokens: input,
            cacheReadInputTokens: usage.cacheRead,
            cacheCreationInputTokens: event.cacheWrite,
            outputTokens: usage.output + usage.reasoning)
        return .init(
            date: day,
            inputTokens: input,
            outputTokens: usage.output,
            cacheReadTokens: usage.cacheRead,
            cacheCreationTokens: event.cacheWrite,
            reasoningTokens: usage.reasoning,
            totalTokens: total,
            requestCount: 1,
            costUSD: costUSD,
            modelsUsed: nil,
            modelBreakdowns: [.init(
                modelName: model,
                costUSD: costUSD,
                totalTokens: total,
                requestCount: 1,
                inputTokens: input,
                outputTokens: usage.output,
                cacheReadTokens: usage.cacheRead,
                cacheCreationTokens: event.cacheWrite,
                reasoningTokens: usage.reasoning)],
            unpricedRequestCount: costUSD == nil ? 1 : nil,
            estimatedRequestCount: costUSD != nil ? 1 : nil)
    }

    private static func checkedMergeEntry(
        _ existing: CostUsageDailyReport.Entry,
        _ new: CostUsageDailyReport.Entry) -> CostUsageDailyReport.Entry?
    {
        guard let input = self.checkedAdd(existing.inputTokens ?? 0, new.inputTokens ?? 0),
              let output = self.checkedAdd(existing.outputTokens ?? 0, new.outputTokens ?? 0),
              let read = self.checkedAdd(existing.cacheReadTokens ?? 0, new.cacheReadTokens ?? 0),
              let creation = self.checkedAdd(existing.cacheCreationTokens ?? 0, new.cacheCreationTokens ?? 0),
              let reason = self.checkedAdd(existing.reasoningTokens ?? 0, new.reasoningTokens ?? 0),
              let total = self.checkedAdd(existing.totalTokens ?? 0, new.totalTokens ?? 0),
              let requests = self.checkedAdd(existing.requestCount ?? 0, new.requestCount ?? 0),
              let unpriced = self.checkedAdd(
                  existing.unpricedRequestCount ?? 0,
                  new.unpricedRequestCount ?? 0),
              let estimated = self.checkedAdd(
                  existing.estimatedRequestCount ?? 0,
                  new.estimatedRequestCount ?? 0)
        else { return nil }
        let breakdowns: [CostUsageDailyReport.ModelBreakdown]?
        if let ex = existing.modelBreakdowns, let nw = new.modelBreakdowns {
            var merged = ex
            for b in nw {
                guard let updated = self.checkedMergeBreakdown(
                    merged,
                    model: b.modelName,
                    costUSD: b.costUSD,
                    tokens: b.totalTokens ?? 0,
                    requestCount: b.requestCount ?? 1,
                    inputTokens: b.inputTokens,
                    outputTokens: b.outputTokens,
                    cacheReadTokens: b.cacheReadTokens,
                    cacheCreationTokens: b.cacheCreationTokens,
                    reasoningTokens: b.reasoningTokens) else { return nil }
                merged = updated
            }
            breakdowns = merged
        } else {
            breakdowns = existing.modelBreakdowns ?? new.modelBreakdowns
        }
        let entryCosts = breakdowns?.compactMap(\.costUSD) ?? []
        let entryCost: Double? = entryCosts.isEmpty ? nil : entryCosts.reduce(0, +)
        return CostUsageDailyReport.Entry(
            date: existing.date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: read,
            cacheCreationTokens: creation,
            reasoningTokens: reason,
            totalTokens: total,
            requestCount: requests,
            costUSD: entryCost,
            modelsUsed: nil,
            modelBreakdowns: breakdowns,
            unpricedRequestCount: unpriced > 0 ? unpriced : nil,
            estimatedRequestCount: estimated > 0 ? estimated : nil)
    }

    private static func checkedMergeBreakdown(
        _ ex: [CostUsageDailyReport.ModelBreakdown]?,
        model: String,
        costUSD: Double?,
        tokens: Int,
        requestCount: Int = 1,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        var arr = ex ?? []
        if let i = arr.firstIndex(where: { $0.modelName == model }) {
            let b = arr[i]
            guard let newTotal = self.checkedAdd(b.totalTokens ?? 0, tokens),
                  let newRequests = self.checkedAdd(b.requestCount ?? 0, requestCount),
                  let newInput = self.checkedAdd(b.inputTokens ?? 0, inputTokens ?? 0),
                  let newOutput = self.checkedAdd(b.outputTokens ?? 0, outputTokens ?? 0),
                  let newRead = self.checkedAdd(b.cacheReadTokens ?? 0, cacheReadTokens ?? 0),
                  let newCreate = self.checkedAdd(b.cacheCreationTokens ?? 0, cacheCreationTokens ?? 0),
                  let newReason = self.checkedAdd(b.reasoningTokens ?? 0, reasoningTokens ?? 0) else { return nil }
            let mergedCost: Double? = if let existing = b.costUSD, let incoming = costUSD {
                existing + incoming
            } else {
                b.costUSD ?? costUSD
            }
            arr[i] = CostUsageDailyReport.ModelBreakdown(
                modelName: b.modelName,
                costUSD: mergedCost,
                totalTokens: newTotal,
                requestCount: newRequests,
                inputTokens: newInput,
                outputTokens: newOutput,
                cacheReadTokens: newRead,
                cacheCreationTokens: newCreate,
                reasoningTokens: newReason)
        } else {
            arr.append(CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: costUSD,
                totalTokens: tokens,
                requestCount: requestCount,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                reasoningTokens: reasoningTokens))
        }
        return arr
    }
}
