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
        /// Two sources disagreed about the same request's payload, so the rows that survived may
        /// be wrong rather than merely incomplete. Unlike a truncated scan, this evidence cannot
        /// be published as a lower bound.
        let evidenceIsContradicted: Bool
        /// An immutable SQLite read observed the database change beneath it, so its rows cannot
        /// be established as one valid snapshot and must not be published.
        let evidenceIsUnstable: Bool

        init(
            report: CostUsageDailyReport,
            coverage: Coverage,
            statistics: Statistics,
            evidenceIsContradicted: Bool = false,
            evidenceIsUnstable: Bool = false)
        {
            self.report = report
            self.coverage = coverage
            self.statistics = statistics
            self.evidenceIsContradicted = evidenceIsContradicted
            self.evidenceIsUnstable = evidenceIsUnstable
        }

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
                  let total = CheckedSum.integers(
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
        var containsHistorySource = false
        var evidenceIsUnstable = false
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

    /// Antigravity records routing variants of a vendor model (`-tiered`, `-low`, `-thinking`)
    /// that bill at the base model's public price. The alias stays provider-local so shared
    /// Claude pricing keeps reporting unknown Claude variants as unpriced.
    static func pricingBaseModelID(for model: String) -> String? {
        let lowered = model.lowercased()
        guard let suffix = self.routingVariantSuffixes.first(where: lowered.hasSuffix) else { return nil }
        let base = String(model.dropLast(suffix.count))
        return base.isEmpty ? nil : base
    }

    private static let routingVariantSuffixes = ["-tiered", "-low", "-thinking"]

    static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    static func makeDailyReportWithStatus(
        context: Context,
        calendar: Calendar = .current,
        estimateCost: Bool = false,
        pricingCacheRoot: URL? = nil,
        limits: Limits = Limits(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> DailyReportResult
    {
        let budget = Budget(limits: limits, clock: clock, cancellation: checkCancellation)
        let pricing = estimateCost ? CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: pricingCacheRoot) : nil
        do {
            let databases = try self.discover(roots: context.databaseRoots, extension: "db", budget: budget)
            // A discovery error is not absence and never authorizes a cache replacement.
            if !databases.paths.isEmpty || !databases.isComplete {
                let source = try self.readDatabases(databases.paths, budget: budget)
                return try self.aggregate(
                    source,
                    discoveryComplete: databases.isComplete,
                    calendar: calendar,
                    budget: budget,
                    pricing: pricing)
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
                budget: budget,
                pricing: pricing)
        } catch ScanFailure.exhausted, ScanFailure.schemaExhausted {
            return DailyReportResult(
                report: .init(data: [], summary: nil), coverage: .partial, statistics: budget.statistics)
        }
    }

    private static func aggregate(
        _ source: SourceResult,
        discoveryComplete: Bool,
        calendar: Calendar,
        budget: Budget,
        pricing: CostUsagePricing.ClaudeResolver?) throws -> DailyReportResult
    {
        var isComplete = discoveryComplete && source.isComplete
            && budget.statistics.sqliteHandlesOpened == budget.statistics.sqliteHandlesClosed
        var contradicted = false
        if isComplete, !source.containsHistorySource {
            return DailyReportResult(
                report: .init(data: [], summary: nil), coverage: .unavailable, statistics: budget.statistics)
        }
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
                event, models: models, conflicts: conflicts, calendar: calendar, pricing: pricing)
            else {
                isComplete = false
                continue
            }
            if let prior = rows[row] {
                // Same filename/session and idx identifies a copied SQLite row, not its token payload.
                if prior != event {
                    isComplete = false
                    contradicted = true
                }
                continue
            }
            let response = event.turn.usage?.responseID.map {
                ResponseIdentity(session: event.session, response: $0)
            }
            if let response, let prior = responses[response] {
                if prior.turn != event.turn || prior.cacheWrite != event.cacheWrite {
                    isComplete = false
                    contradicted = true
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
        let total = CheckedSum.integers(daily.compactMap(\.totalTokens))
        let costs = daily.compactMap(\.costUSD)
        return DailyReportResult(
            report: .init(
                data: daily,
                summary: daily.isEmpty ? nil : .init(
                    totalInputTokens: nil,
                    totalOutputTokens: nil,
                    totalTokens: total,
                    totalCostUSD: costs.isEmpty ? nil : costs.reduce(0, +))),
            coverage: isComplete ? .complete : .partial,
            statistics: budget.statistics,
            evidenceIsContradicted: contradicted,
            evidenceIsUnstable: source.evidenceIsUnstable)
    }

    private static func entry(
        _ event: Event,
        models: [LabelIdentity: String],
        conflicts: Set<LabelIdentity>,
        calendar: Calendar,
        pricing: CostUsagePricing.ClaudeResolver?) -> CostUsageDailyReport.Entry?
    {
        guard let usage = event.turn.usage, let timestamp = event.turn.timestampMs
        else { return nil }
        let input = event.input
        let total = event.total
        let label = event.turn.label.map { LabelIdentity(session: event.session, label: $0) }
        let inherited = label.flatMap { conflicts.contains($0) ? nil : models[$0] }
        let model = self.normalizeModelID(event.turn.model ?? inherited ?? "unknown")
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let cost = pricing.flatMap {
            self.costUSD(
                pricing: $0,
                model: model,
                date: date,
                tokens: PricedTokens(
                    input: input,
                    cacheRead: usage.cacheRead,
                    cacheCreation: event.cacheWrite,
                    output: usage.output + usage.reasoning))
        }
        let day = CostUsageLocalDay.key(from: date, calendar: calendar)
        return .init(
            date: day,
            inputTokens: input,
            outputTokens: usage.output,
            cacheReadTokens: usage.cacheRead,
            cacheCreationTokens: event.cacheWrite,
            reasoningTokens: usage.reasoning,
            totalTokens: total,
            requestCount: 1,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [.init(
                modelName: model,
                costUSD: cost,
                totalTokens: total,
                requestCount: 1,
                inputTokens: input,
                outputTokens: usage.output,
                cacheReadTokens: usage.cacheRead,
                cacheCreationTokens: event.cacheWrite,
                reasoningTokens: usage.reasoning)],
            unpricedRequestCount: cost == nil ? 1 : 0,
            estimatedRequestCount: cost == nil ? 0 : 1)
    }

    private struct PricedTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreation: Int
        let output: Int
    }

    /// Prices the exact recorded model ID first so an explicitly catalogued variant keeps its own
    /// price, then falls back to the base model of a known routing variant.
    private static func costUSD(
        pricing: CostUsagePricing.ClaudeResolver,
        model: String,
        date: Date,
        tokens: PricedTokens) -> Double?
    {
        func resolve(_ candidate: String) -> Double? {
            pricing.costUSD(
                model: candidate,
                inputTokens: tokens.input,
                cacheReadInputTokens: tokens.cacheRead,
                cacheCreationInputTokens: tokens.cacheCreation,
                outputTokens: tokens.output,
                pricingDate: date)
        }
        if let cost = resolve(model) { return cost }
        guard let base = self.pricingBaseModelID(for: model) else { return nil }
        return resolve(base)
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
              let requests = self.checkedAdd(existing.requestCount ?? 0, new.requestCount ?? 0) else { return nil }
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
        return CostUsageDailyReport.Entry(
            date: existing.date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: read,
            cacheCreationTokens: creation,
            reasoningTokens: reason,
            totalTokens: total,
            requestCount: requests,
            costUSD: self.sumCosts(existing.costUSD, new.costUSD),
            modelsUsed: nil,
            modelBreakdowns: breakdowns,
            unpricedRequestCount: existing.unpricedRequestCount.flatMap { old in
                self.checkedAdd(old, new.unpricedRequestCount ?? 0)
            },
            estimatedRequestCount: existing.estimatedRequestCount.flatMap { old in
                self.checkedAdd(old, new.estimatedRequestCount ?? 0)
            })
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
            arr[i] = CostUsageDailyReport.ModelBreakdown(
                modelName: b.modelName,
                costUSD: self.sumCosts(b.costUSD, costUSD),
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

    private static func sumCosts(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs + rhs
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}
