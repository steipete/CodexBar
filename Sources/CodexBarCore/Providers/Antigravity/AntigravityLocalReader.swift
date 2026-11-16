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
        /// True when a bounded incremental batch stopped early and remaining conversations can make progress.
        let catchUpPending: Bool
        /// True when at least one uncached/changed database completed cleanly in this batch.
        let batchMadeProgress: Bool
        /// Original capture time when returning a previously complete snapshot during catch-up.
        let retainedUpdatedAt: Date?

        init(
            report: CostUsageDailyReport,
            coverage: Coverage,
            statistics: Statistics,
            evidenceIsContradicted: Bool = false,
            evidenceIsUnstable: Bool = false,
            catchUpPending: Bool = false,
            batchMadeProgress: Bool = false,
            retainedUpdatedAt: Date? = nil)
        {
            self.report = report
            self.coverage = coverage
            self.statistics = statistics
            self.evidenceIsContradicted = evidenceIsContradicted
            self.evidenceIsUnstable = evidenceIsUnstable
            self.catchUpPending = catchUpPending
            self.batchMadeProgress = batchMadeProgress
            self.retainedUpdatedAt = retainedUpdatedAt
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
                  let total = CheckedSum.integers(
                      [usage.newInput, usage.output, usage.cacheRead, cacheWrite, usage.reasoning])
            else { return nil }
            self.session = session
            self.row = row
            self.turn = turn
            self.cacheWrite = cacheWrite
            self.input = usage.newInput
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

    struct LabelIdentity: Hashable {
        let session: String
        let label: String
    }

    static func normalizeModelID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    /// Antigravity records routing variants of a vendor model (`-tiered`, `-low`, `-thinking`)
    /// that bill at the base model's public price, and product aliases that name no catalogued
    /// model at all. The alias stays provider-local so shared Claude pricing keeps reporting
    /// unknown Claude variants as unpriced.
    static func pricingBaseModelID(for model: String) -> String? {
        let lowered = model.lowercased()
        if let alias = self.pricingModelAliases[lowered] { return alias }
        guard let suffix = self.routingVariantSuffixes.first(where: lowered.hasSuffix) else { return nil }
        let base = String(model.dropLast(suffix.count))
        return base.isEmpty ? nil : self.pricingModelAliases[base.lowercased()] ?? base
    }

    private static let routingVariantSuffixes = ["-tiered", "-low", "-thinking"]

    /// Gemini 3.1 Pro is catalogued only as `gemini-3.1-pro-preview`. Antigravity records it under
    /// its product aliases and effort tiers; ccusage's Antigravity adapter maps the same IDs.
    /// Antigravity also records safety-routed Gemini 3.7 Flash turns under `gemini-3.7-flash-safety-le`
    /// while the usage record's model enum ID matches ordinary `gemini-3.7-flash` turns.
    private static let pricingModelAliases = [
        "gemini-pro-default": "gemini-3.1-pro-preview",
        "gemini-pro-agent": "gemini-3.1-pro-preview",
        "gemini-3.1-pro": "gemini-3.1-pro-preview",
        "gemini-3.1-pro-high": "gemini-3.1-pro-preview",
        "gemini-3.1-pro-low": "gemini-3.1-pro-preview",
        "gemini-3.7-flash-safety-le": "gemini-3.7-flash",
    ]

    /// `gpt-oss-120b` is an open-weight model, so no first-party vendor lists a price for it.
    /// Google serves it inside Antigravity, so the Google Vertex list price applies. Antigravity
    /// records it as `gpt-oss-120b-medium`, which the shared Claude pricing never routes to Vertex.
    /// Only the exact recorded name is mapped, so other effort tiers stay unpriced.
    private static let explicitCatalogEntries = [
        "gpt-oss-120b-medium": (providerID: "google-vertex", modelID: "openai/gpt-oss-120b-maas"),
    ]

    /// Every catalog entry `costUSD` may price `model` with, so an unknown-price refresh fetches them all.
    /// Antigravity prices through the Claude resolver, and its routing variants resolve against the
    /// base vendor model, so both IDs are worth fetching, plus any explicit catalog entry.
    static func pricingRefreshTargets(for model: String) -> [(providerID: String, modelID: String)] {
        let names = [model] + [self.pricingBaseModelID(for: model)].compactMap(\.self)
        var targets = names.flatMap { CostUsagePricing.claudeModelsDevPricingTargets(for: $0) }
        if let entry = self.explicitCatalogEntries[model.lowercased()] {
            targets.append(entry)
        }
        return targets
    }

    static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    static func makeDailyReportWithStatus(
        context: Context,
        calendar: Calendar = .current,
        estimateCost: Bool = false,
        pricingCacheRoot: URL? = nil,
        scanCacheRoot: URL? = nil,
        now: Date = Date(),
        limits: Limits = Limits(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> DailyReportResult
    {
        let budget = Budget(limits: limits, clock: clock, cancellation: checkCancellation)
        let pricing = estimateCost ? CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: pricingCacheRoot) : nil
        if let scanCacheRoot {
            return try self.makeIncrementalDailyReportWithStatus(
                IncrementalScanRequest(
                    context: context,
                    calendar: calendar,
                    estimateCost: estimateCost,
                    pricing: pricing,
                    scanCacheRoot: scanCacheRoot,
                    now: now,
                    budget: budget))
        }
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

    static func aggregate(
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

    static func entry(
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
        let day = CostUsageLocalDay.key(from: date, calendar: calendar)
        let unattributedZero = total == 0 && model == "unknown"
        let cost = pricing.flatMap {
            unattributedZero ? 0 : self.costUSD(
                pricing: $0,
                model: model,
                date: date,
                usage: usage,
                cacheWrite: event.cacheWrite)
        }
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
            modelBreakdowns: unattributedZero ? [] : [.init(
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

    /// Prices the exact recorded model ID first so an explicitly catalogued variant keeps its own
    /// price, then falls back to the base model of a known routing variant, then to an explicit
    /// catalog entry for a model that no first-party vendor prices.
    static func costUSD(
        pricing: CostUsagePricing.ClaudeResolver,
        model: String,
        date: Date,
        usage: AntigravityProtoReader.ParsedUsage,
        cacheWrite: Int) -> Double?
    {
        func resolve(_ candidate: String, providerID: String? = nil) -> Double? {
            pricing.costUSD(
                model: candidate,
                providerID: providerID,
                inputTokens: usage.newInput,
                cacheReadInputTokens: usage.cacheRead,
                cacheCreationInputTokens: cacheWrite,
                outputTokens: usage.output + usage.reasoning,
                pricingDate: date)
        }
        if let cost = resolve(model) { return cost }
        if let base = self.pricingBaseModelID(for: model), let cost = resolve(base) { return cost }
        guard let entry = self.explicitCatalogEntries[model.lowercased()] else { return nil }
        return resolve(entry.modelID, providerID: entry.providerID)
    }

    static func checkedMergeEntry(
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
        if let lhs, let rhs { return lhs + rhs }
        return lhs ?? rhs
    }
}
