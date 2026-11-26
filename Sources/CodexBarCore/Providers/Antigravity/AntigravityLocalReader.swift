import Foundation

enum AntigravityLocalReader {
    enum Coverage: Sendable {
        case complete
        case partial
        case unavailable
    }

    struct ConversationSummaryMetadata: Equatable, Sendable {
        let title: String?
        let workspaceURIs: [String]
        let projectID: String?
        let parentConversationID: String?
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
        let projects: [CostUsageProjectBreakdown]
        let sessions: [CostUsageSessionBreakdown]

        init(
            report: CostUsageDailyReport,
            coverage: Coverage,
            statistics: Statistics,
            evidenceIsContradicted: Bool = false,
            evidenceIsUnstable: Bool = false,
            projects: [CostUsageProjectBreakdown] = [],
            sessions: [CostUsageSessionBreakdown] = [])
        {
            self.report = report
            self.coverage = coverage
            self.statistics = statistics
            self.evidenceIsContradicted = evidenceIsContradicted
            self.evidenceIsUnstable = evidenceIsUnstable
            self.projects = projects
            self.sessions = sessions
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
        var trajectoryMetadataBySession: [String: AntigravityProtoReader.TrajectoryMetadata] = [:]
        var conversationSummariesBySession: [String: ConversationSummaryMetadata] = [:]
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
        limits: Limits = Limits(),
        includeBreakdowns: Bool = false,
        dayRange: (sinceKey: String, untilKey: String)? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}) throws -> DailyReportResult
    {
        let budget = Budget(limits: limits, clock: clock, cancellation: checkCancellation)
        let pricing = estimateCost ? CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: pricingCacheRoot) : nil
        do {
            let databases = try self.discover(roots: context.databaseRoots, extension: "db", budget: budget)
            // A discovery error is not absence and never authorizes a cache replacement.
            if !databases.paths.isEmpty || !databases.isComplete {
                var source = try self.readDatabases(
                    databases.paths,
                    budget: budget,
                    includeBreakdowns: includeBreakdowns)
                if includeBreakdowns {
                    source.conversationSummariesBySession = try self.readConversationSummaries(
                        urls: context.conversationSummaryDatabases,
                        budget: budget)
                }
                return try self.aggregate(
                    source,
                    discoveryComplete: databases.isComplete,
                    calendar: calendar,
                    budget: budget,
                    pricing: pricing,
                    includeBreakdowns: includeBreakdowns,
                    dayRange: dayRange,
                    projectGrouping: context.scanOptions.projectGrouping)
            }
            guard context.scanOptions.includeTokscaleFallback else {
                return DailyReportResult(
                    report: .init(data: [], summary: nil), coverage: .unavailable, statistics: budget.statistics)
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
                pricing: pricing,
                includeBreakdowns: includeBreakdowns,
                dayRange: dayRange,
                projectGrouping: context.scanOptions.projectGrouping)
        } catch ScanFailure.exhausted, ScanFailure.schemaExhausted {
            return DailyReportResult(
                report: .init(data: [], summary: nil), coverage: .partial, statistics: budget.statistics)
        }
    }

    fileprivate struct AcceptedEvent {
        let event: Event
        let entry: CostUsageDailyReport.Entry
    }

    private static func aggregate(
        _ source: SourceResult,
        discoveryComplete: Bool,
        calendar: Calendar,
        budget: Budget,
        pricing: CostUsagePricing.ClaudeResolver?,
        includeBreakdowns: Bool = false,
        dayRange: (sinceKey: String, untilKey: String)? = nil,
        projectGrouping: AntigravityProjectGrouping = .workspace) throws -> DailyReportResult
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
        var hourlyBuckets: [Date: CostUsageTemporalTotals] = [:]
        var sliceBuckets: [Date: CostUsageTemporalTotals] = [:]
        var acceptedEvents: [AcceptedEvent] = []
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
            if let timestampMs = event.turn.timestampMs {
                let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
                let hour = CostUsageScanner.hourStart(for: timestamp, calendar: calendar)
                let costIsComplete = entry.costUSD != nil
                hourlyBuckets[hour, default: CostUsageTemporalTotals()].add(
                    totalTokens: event.total,
                    costUSD: entry.costUSD,
                    tokensAreComplete: true,
                    costIsComplete: costIsComplete)
                sliceBuckets[timestamp, default: CostUsageTemporalTotals()].add(
                    totalTokens: event.total,
                    costUSD: entry.costUSD,
                    tokensAreComplete: true,
                    costIsComplete: costIsComplete)
            }
            if includeBreakdowns {
                let inRange = dayRange.map { entry.date >= $0.sinceKey && entry.date <= $0.untilKey } ?? true
                if inRange {
                    acceptedEvents.append(AcceptedEvent(event: event, entry: entry))
                }
            }
        }
        let daily = entries.values.sorted { $0.date < $1.date }
        let total = CheckedSum.integers(daily.compactMap(\.totalTokens))
        let costs = daily.compactMap(\.costUSD)
        let hourly = CostUsageScanner.sortedHourlyEntries(hourlyBuckets)
        let quotaSlices = CostUsageScanner.sortedQuotaSlices(sliceBuckets)
        let breakdowns = includeBreakdowns
            ? self.buildBreakdowns(
                acceptedEvents: acceptedEvents,
                source: source,
                projectGrouping: projectGrouping)
            : (projects: [CostUsageProjectBreakdown](), sessions: [CostUsageSessionBreakdown]())
        return DailyReportResult(
            report: .init(
                data: daily,
                summary: daily.isEmpty ? nil : .init(
                    totalInputTokens: nil,
                    totalOutputTokens: nil,
                    totalTokens: total,
                    totalCostUSD: costs.isEmpty ? nil : costs.reduce(0, +)),
                hourly: hourly,
                quotaSlices: quotaSlices),
            coverage: isComplete ? .complete : .partial,
            statistics: budget.statistics,
            evidenceIsContradicted: contradicted,
            evidenceIsUnstable: source.evidenceIsUnstable,
            projects: breakdowns.projects,
            sessions: breakdowns.sessions)
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
    private static func costUSD(
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

    fileprivate static func checkedMergeEntry(
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

extension AntigravityLocalReader {
    private struct ResolvedProjectIdentity {
        let projectKey: String
        let projectName: String
        let canonicalPath: String?
        let sourcePath: String?
        let sourceName: String
    }

    fileprivate static func buildBreakdowns(
        acceptedEvents: [AcceptedEvent],
        source: SourceResult,
        projectGrouping: AntigravityProjectGrouping)
        -> (projects: [CostUsageProjectBreakdown], sessions: [CostUsageSessionBreakdown])
    {
        guard !acceptedEvents.isEmpty else { return ([], []) }

        let eventsBySession = Dictionary(grouping: acceptedEvents, by: \.event.session)
        let sortedSessionIDs = eventsBySession.keys.sorted()
        var resolvedBySession: [String: ResolvedProjectIdentity] = [:]
        resolvedBySession.reserveCapacity(sortedSessionIDs.count)
        var projectEventsByKey: [String: (identities: [ResolvedProjectIdentity], events: [AcceptedEvent])] = [:]

        for sessionID in sortedSessionIDs {
            guard let items = eventsBySession[sessionID] else { continue }
            let resolvedProject = self.resolveProjectIdentity(
                sessionID: sessionID,
                source: source,
                projectGrouping: projectGrouping)
            resolvedBySession[sessionID] = resolvedProject
            projectEventsByKey[resolvedProject.projectKey, default: ([], [])].identities.append(resolvedProject)
            projectEventsByKey[resolvedProject.projectKey, default: ([], [])].events.append(contentsOf: items)
        }

        var representativeByKey: [String: ResolvedProjectIdentity] = [:]
        representativeByKey.reserveCapacity(projectEventsByKey.count)
        for (projectKey, group) in projectEventsByKey {
            representativeByKey[projectKey] = self.representativeProjectIdentity(from: group.identities)
        }

        var sessions: [CostUsageSessionBreakdown] = []
        sessions.reserveCapacity(sortedSessionIDs.count)

        for sessionID in sortedSessionIDs {
            guard let items = eventsBySession[sessionID],
                  let resolvedProject = resolvedBySession[sessionID]
            else { continue }
            let representative = representativeByKey[resolvedProject.projectKey] ?? resolvedProject

            let daily = self.mergedDailyEntries(from: items.map(\.entry))
            let summaryTotal = CheckedSum.integers(items.map(\.event.total))
            let newInput = CheckedSum.integers(items.map(\.event.input))
            let cacheRead = CheckedSum.integers(items.map { $0.event.turn.usage?.cacheRead ?? 0 })
            let cacheWrite = CheckedSum.integers(items.map(\.event.cacheWrite))
            let output = CheckedSum.integers(items.map { $0.event.turn.usage?.output ?? 0 })
            let reasoning = CheckedSum.integers(items.map { $0.event.turn.usage?.reasoning ?? 0 })
            let inputTokens = [newInput, cacheRead, cacheWrite].allSatisfy { $0 != nil }
                ? CheckedSum.integers([newInput ?? 0, cacheRead ?? 0, cacheWrite ?? 0])
                : nil
            let outputTokens = [output, reasoning].allSatisfy { $0 != nil }
                ? CheckedSum.integers([output ?? 0, reasoning ?? 0])
                : nil
            let costs = daily.compactMap(\.costUSD)
            let lastActivityMs = items.compactMap(\.event.turn.timestampMs).max() ?? 0
            let modelBreakdowns = CostUsageDailyReport.sortedModelBreakdowns(
                CostUsageDailyReport.modelCostSummaries(from: daily))
            let title = source.conversationSummariesBySession[sessionID]?.title

            sessions.append(CostUsageSessionBreakdown(
                sessionID: sessionID,
                lastActivity: Date(timeIntervalSince1970: Double(lastActivityMs) / 1000),
                inputTokens: inputTokens,
                cachedInputTokens: cacheRead,
                outputTokens: outputTokens,
                reasoningTokens: reasoning,
                totalTokens: summaryTotal,
                requestCount: items.count,
                costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                modelBreakdowns: modelBreakdowns,
                projectPath: representative.canonicalPath,
                projectName: representative.canonicalPath == nil && representative.projectKey.isEmpty
                    ? nil
                    : representative.projectName,
                title: title))
        }

        sessions.sort { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID > rhs.sessionID
        }

        var projects: [CostUsageProjectBreakdown] = []
        projects.reserveCapacity(projectEventsByKey.count)
        for (projectKey, group) in projectEventsByKey {
            let daily = self.mergedDailyEntries(from: group.events.map(\.entry))
            guard !daily.isEmpty else { continue }
            let totalTokens = CheckedSum.integers(daily.compactMap(\.totalTokens))
            let costs = daily.compactMap(\.costUSD)
            let totalCostUSD = costs.isEmpty ? nil : costs.reduce(0, +)
            let modelSummaries = CostUsageDailyReport.modelCostSummaries(from: daily)
            let modelBreakdowns = modelSummaries.isEmpty
                ? nil
                : CostUsageDailyReport.sortedModelBreakdowns(modelSummaries)

            let representative = representativeByKey[projectKey]
                ?? self.representativeProjectIdentity(from: group.identities)
            let eventsBySource = Dictionary(grouping: group.events) { item in
                resolvedBySession[item.event.session]?.sourcePath ?? ""
            }
            let projectSources: [CostUsageProjectSourceBreakdown] = eventsBySource.map { sourceKey, sourceItems in
                let sourceDaily = self.mergedDailyEntries(from: sourceItems.map(\.entry))
                let sourceTokens = CheckedSum.integers(sourceDaily.compactMap(\.totalTokens))
                let sourceCosts = sourceDaily.compactMap(\.costUSD)
                let sourceModelSummaries = CostUsageDailyReport.modelCostSummaries(from: sourceDaily)
                let sourceBreakdowns = sourceModelSummaries.isEmpty
                    ? nil
                    : CostUsageDailyReport.sortedModelBreakdowns(sourceModelSummaries)
                let resolvedPath = sourceKey.isEmpty ? representative.canonicalPath : sourceKey
                let sourceName = resolvedPath.map(self.directoryDisplayName(path:)) ?? representative.projectName
                return CostUsageProjectSourceBreakdown(
                    name: sourceName,
                    path: resolvedPath,
                    totalTokens: sourceTokens,
                    totalCostUSD: sourceCosts.isEmpty ? nil : sourceCosts.reduce(0, +),
                    daily: sourceDaily,
                    modelBreakdowns: sourceBreakdowns)
            }.sorted { lhs, rhs in
                let lhsRank = (lhs.totalCostUSD ?? -1, lhs.totalTokens ?? -1)
                let rhsRank = (rhs.totalCostUSD ?? -1, rhs.totalTokens ?? -1)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                return (lhs.path ?? lhs.name) < (rhs.path ?? rhs.name)
            }

            projects.append(CostUsageProjectBreakdown(
                name: representative.projectName,
                path: representative.canonicalPath,
                totalTokens: totalTokens,
                totalCostUSD: totalCostUSD,
                daily: daily,
                modelBreakdowns: modelBreakdowns,
                sources: projectSources))
        }

        projects.sort { lhs, rhs in
            let lhsRank = (lhs.totalCostUSD ?? -1, lhs.totalTokens ?? -1)
            let rhsRank = (rhs.totalCostUSD ?? -1, rhs.totalTokens ?? -1)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return (projects, sessions)
    }

    private static func mergedDailyEntries(from entries: [CostUsageDailyReport.Entry]) -> [CostUsageDailyReport.Entry] {
        var byDate: [String: CostUsageDailyReport.Entry] = [:]
        for entry in entries {
            if let existing = byDate[entry.date],
               let merged = self.checkedMergeEntry(existing, entry)
            {
                byDate[entry.date] = merged
            } else if byDate[entry.date] == nil {
                byDate[entry.date] = entry
            }
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    private static func representativeProjectIdentity(
        from identities: [ResolvedProjectIdentity]) -> ResolvedProjectIdentity
    {
        guard let first = identities.first else {
            return ResolvedProjectIdentity(
                projectKey: "",
                projectName: CostUsageProjectBreakdown.unknownProjectName,
                canonicalPath: nil,
                sourcePath: nil,
                sourceName: CostUsageProjectBreakdown.unknownProjectName)
        }
        let nonWorktree = identities.first { identity in
            guard let path = identity.canonicalPath else { return false }
            return !path.contains("/.gemini/antigravity/worktrees/")
        }
        let anyPath = identities
            .filter { $0.canonicalPath != nil }
            .min { lhs, rhs in
                let lPath = lhs.canonicalPath ?? ""
                let rPath = rhs.canonicalPath ?? ""
                if lPath.count != rPath.count { return lPath.count < rPath.count }
                return lPath < rPath
            }
        return nonWorktree ?? anyPath ?? first
    }

    private static func resolveProjectIdentity(
        sessionID: String,
        source: SourceResult,
        projectGrouping: AntigravityProjectGrouping) -> ResolvedProjectIdentity
    {
        let trajectory = source.trajectoryMetadataBySession[sessionID]
        let summary = source.conversationSummariesBySession[sessionID]
        let workspacePath = self.normalizedLocalPath(trajectory?.primaryWorkspaceURI)
            ?? trajectory?.workspaces.lazy.compactMap { self.normalizedLocalPath($0.workspaceURI) }.first
            ?? summary?.workspaceURIs.lazy.compactMap { self.normalizedLocalPath($0) }.first
        let gitRootPath = trajectory?.workspaces.lazy.compactMap { self.normalizedLocalPath($0.gitRootURI) }.first

        switch projectGrouping {
        case .workspace:
            let path = workspacePath ?? gitRootPath
            let name = path.map(self.directoryDisplayName(path:)) ?? CostUsageProjectBreakdown.unknownProjectName
            return ResolvedProjectIdentity(
                projectKey: path ?? "",
                projectName: name,
                canonicalPath: path,
                sourcePath: path,
                sourceName: name)
        case .gitRepository:
            let repoWorkspace = trajectory?.workspaces.first { workspace in
                let hasSlug = workspace.repoSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                let hasRemote = workspace.repoRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
                return hasSlug || hasRemote
            }
            let repoSlug = trajectory?.workspaces.lazy
                .compactMap { $0.repoSlug?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let repoRemoteURL = trajectory?.workspaces.lazy
                .compactMap { $0.repoRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let repo = Self.canonicalRepositoryIdentity(repoSlug: repoSlug, repoRemoteURL: repoRemoteURL) {
                let repoGitRoot = self.normalizedLocalPath(repoWorkspace?.gitRootURI) ?? gitRootPath
                let repoWorkspacePath = self.normalizedLocalPath(repoWorkspace?.workspaceURI) ?? workspacePath
                let sourcePath = repoWorkspacePath ?? repoGitRoot
                let nonWorktreeGitRoot = repoGitRoot?.contains("/.gemini/antigravity/worktrees/") == false
                    ? repoGitRoot
                    : nil
                let nonWorktreeSource = sourcePath?.contains("/.gemini/antigravity/worktrees/") == false
                    ? sourcePath
                    : nil
                let canonical = nonWorktreeGitRoot ?? nonWorktreeSource ?? repoGitRoot ?? sourcePath
                let effectiveSourcePath = sourcePath ?? canonical
                let sourceName = effectiveSourcePath.map(self.directoryDisplayName(path:)) ?? repo.name
                return ResolvedProjectIdentity(
                    projectKey: repo.key,
                    projectName: repo.name,
                    canonicalPath: canonical,
                    sourcePath: effectiveSourcePath,
                    sourceName: sourceName)
            }
            let fallbackPath = gitRootPath ?? workspacePath
            let name = fallbackPath.map(self.directoryDisplayName(path:))
                ?? CostUsageProjectBreakdown.unknownProjectName
            return ResolvedProjectIdentity(
                projectKey: fallbackPath.map { "path:\($0)" } ?? "",
                projectName: name,
                canonicalPath: fallbackPath,
                sourcePath: workspacePath ?? fallbackPath,
                sourceName: (workspacePath ?? fallbackPath).map(self.directoryDisplayName(path:)) ?? name)
        }
    }

    private static func normalizedLocalPath(_ rawURI: String?) -> String? {
        guard let trimmed = rawURI?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL.path
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return nil
    }

    private static func directoryDisplayName(path: String) -> String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func canonicalRepositoryIdentity(
        repoSlug: String?,
        repoRemoteURL: String?) -> (key: String, name: String)?
    {
        if let repoSlug {
            var cleaned = repoSlug
                .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
            if cleaned.lowercased().hasSuffix(".git") {
                cleaned.removeLast(".git".count)
                cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
            }
            if !cleaned.isEmpty {
                return (key: "repo:\(cleaned.lowercased())", name: cleaned)
            }
        }
        if let repoRemoteURL {
            let normalizedRemote = self.normalizedRepositoryName(from: repoRemoteURL)
            guard !normalizedRemote.isEmpty else { return nil }
            if let slug = self.extractOwnerRepoSlug(from: normalizedRemote) {
                return (key: "repo:\(slug.lowercased())", name: slug)
            }
            return (key: "remote:\(normalizedRemote.lowercased())", name: normalizedRemote)
        }
        return nil
    }

    private static func normalizedRepositoryName(from remoteURL: String) -> String {
        var cleaned = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        if cleaned.lowercased().hasSuffix(".git") {
            cleaned.removeLast(".git".count)
        }
        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        if let colonIndex = cleaned.lastIndex(of: ":"), !cleaned.contains("://") {
            var pathPart = String(cleaned[cleaned.index(after: colonIndex)...])
            while pathPart.hasPrefix("/") {
                pathPart.removeFirst()
            }
            if !pathPart.isEmpty { return pathPart }
        }
        if let url = URL(string: cleaned), !url.isFileURL {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 {
                return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
            }
            if let last = parts.last, !last.isEmpty {
                return last
            }
        }
        return cleaned
    }

    private static func extractOwnerRepoSlug(from normalizedRemote: String) -> String? {
        let trimmed = normalizedRemote
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.contains(where: \.isWhitespace)
        else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !parts[0].contains(":"),
              !parts[1].contains(":")
        else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
