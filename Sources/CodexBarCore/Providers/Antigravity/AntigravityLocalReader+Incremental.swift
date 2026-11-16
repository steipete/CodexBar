#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

extension AntigravityLocalReader {
    struct IncrementalScanRequest {
        let context: Context
        let calendar: Calendar
        let estimateCost: Bool
        let pricing: CostUsagePricing.ClaudeResolver?
        let scanCacheRoot: URL
        let now: Date
        let budget: Budget
        var maximumReplayBytes: Int = AntigravityLocalScanCacheIO.defaultMaximumReplayBytes
    }

    private struct RetainedReportOptions {
        let calendar: Calendar
        let estimateCost: Bool
        let statistics: Statistics
        let catchUpPending: Bool
        let batchMadeProgress: Bool
        let allowRetained: Bool
    }

    private struct PendingDatabase {
        let url: URL
        let key: String
        let fingerprintBefore: AntigravityLocalScanCache.DatabaseFingerprint?
    }

    private struct BatchScanOutcome {
        var aggregator: StreamingAggregator
        var batchExhausted = false
        var batchMadeProgress = false
        var replayMadeProgress = false
        var schemaIncomplete = false
        var hadIncompleteSource = false
        var evidenceIsUnstable = false
        var cacheDirty = false
    }

    private struct CompactTurnDigest: Equatable {
        let w0: UInt64
        let w1: UInt64
        let w2: UInt64
        let w3: UInt64

        init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
            self.w0 = w0
            self.w1 = w1
            self.w2 = w2
            self.w3 = w3
        }

        init(_ event: Event) {
            var hasher = SHA256()
            func feed(_ text: String?) {
                guard let text else {
                    hasher.update(data: Data([0]))
                    return
                }
                hasher.update(data: Data([1]))
                var count = UInt64(text.utf8.count).littleEndian
                withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
                hasher.update(data: Data(text.utf8))
            }
            func feedInt(_ value: Int?) {
                guard var v = value.map({ Int64($0).littleEndian }) else {
                    hasher.update(data: Data([0]))
                    return
                }
                hasher.update(data: Data([1]))
                withUnsafeBytes(of: &v) { hasher.update(bufferPointer: $0) }
            }
            var cacheWrite = Int64(event.cacheWrite).littleEndian
            withUnsafeBytes(of: &cacheWrite) { hasher.update(bufferPointer: $0) }
            feedInt(event.turn.timestampMs.map { Int($0) })
            feed(event.turn.model)
            feed(event.turn.label)
            feed(event.turn.stepUUID)
            if let usage = event.turn.usage {
                hasher.update(data: Data([1]))
                feedInt(usage.newInput)
                feedInt(usage.cacheRead)
                feedInt(usage.output)
                feedInt(usage.reasoning)
                feed(usage.responseID)
                feedInt(usage.modelID)
                feed(usage.botID)
            } else {
                hasher.update(data: Data([0]))
            }
            let digest = hasher.finalize()
            var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            digest.withUnsafeBytes { raw in
                let ptr = raw.bindMemory(to: UInt64.self)
                words = (ptr[0], ptr[1], ptr[2], ptr[3])
            }
            self.w0 = words.0
            self.w1 = words.1
            self.w2 = words.2
            self.w3 = words.3
        }
    }

    private struct CompactRowKey: Hashable {
        let sessionID: Int
        let row: Int64
    }

    private struct CompactResponseKey: Hashable {
        let sessionID: Int
        let response: String
    }

    private struct DeferredLabelKey: Hashable, Codable {
        let day: String
        let session: String
        let label: String
        let isHistoricalPricingDate: Bool
        let contextTokens: Int
    }

    private struct DeferredLabelBucket: Codable {
        let sampleDate: Date
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var reasoningTokens: Int
        var totalTokens: Int
        var requestCount: Int

        mutating func add(_ event: Event) -> Bool {
            guard let usage = event.turn.usage,
                  let input = AntigravityLocalReader.checkedAdd(self.inputTokens, event.input),
                  let output = AntigravityLocalReader.checkedAdd(self.outputTokens, usage.output),
                  let read = AntigravityLocalReader.checkedAdd(self.cacheReadTokens, usage.cacheRead),
                  let creation = AntigravityLocalReader.checkedAdd(self.cacheCreationTokens, event.cacheWrite),
                  let reason = AntigravityLocalReader.checkedAdd(self.reasoningTokens, usage.reasoning),
                  let total = AntigravityLocalReader.checkedAdd(self.totalTokens, event.total),
                  let requests = AntigravityLocalReader.checkedAdd(self.requestCount, 1)
            else { return false }
            self.inputTokens = input
            self.outputTokens = output
            self.cacheReadTokens = read
            self.cacheCreationTokens = creation
            self.reasoningTokens = reason
            self.totalTokens = total
            self.requestCount = requests
            return true
        }
    }

    /// Streams cached and newly scanned database events into daily buckets without retaining full `[Event]` arrays.
    private struct StreamingAggregator {
        let calendar: Calendar
        let pricing: CostUsagePricing.ClaudeResolver?
        var containsHistorySource = false
        var combinedIsComplete = true
        private var sessionIDs: [String: Int] = [:]
        private var models: [LabelIdentity: String] = [:]
        private var conflicts = Set<LabelIdentity>()
        private var rows: [CompactRowKey: CompactTurnDigest] = [:]
        private var responses: [CompactResponseKey: CompactTurnDigest] = [:]
        private var entries: [String: CostUsageDailyReport.Entry] = [:]
        private var deferredLabelBuckets: [DeferredLabelKey: DeferredLabelBucket] = [:]
        private var hasMissingFields = false
        private var contradicted = false

        init(calendar: Calendar, pricing: CostUsagePricing.ClaudeResolver?) {
            self.calendar = calendar
            self.pricing = pricing
        }

        private mutating func internSession(_ session: String) -> Int {
            if let existing = self.sessionIDs[session] {
                return existing
            }
            let next = self.sessionIDs.count
            self.sessionIDs[session] = next
            return next
        }

        mutating func ingest(_ events: [Event], budget: Budget? = nil) throws {
            for event in events {
                if let budget { try budget.check() }
                if let label = event.turn.label, let model = event.turn.model {
                    let key = LabelIdentity(session: event.session, label: label)
                    if let prior = self.models[key], prior != model {
                        self.conflicts.insert(key)
                    } else {
                        self.models[key] = model
                    }
                }
                guard let usage = event.turn.usage, let timestamp = event.turn.timestampMs else {
                    self.hasMissingFields = true
                    continue
                }
                let sessionID = self.internSession(event.session)
                let rowKey = CompactRowKey(sessionID: sessionID, row: event.row)
                let digest = CompactTurnDigest(event)
                if let prior = self.rows[rowKey] {
                    if prior != digest {
                        self.contradicted = true
                    }
                    continue
                }
                let responseKey = usage.responseID.map {
                    CompactResponseKey(sessionID: sessionID, response: $0)
                }
                if let responseKey, let prior = self.responses[responseKey] {
                    if prior != digest {
                        self.contradicted = true
                    } else {
                        self.rows[rowKey] = digest
                    }
                    continue
                }
                if event.turn.model == nil, let label = event.turn.label {
                    let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
                    let day = CostUsageLocalDay.key(from: date, calendar: self.calendar)
                    let isHistoricalPricingDate = date < Date(timeIntervalSince1970: 1_773_360_000)
                    let contextTokens = CheckedSum.integers([event.input, usage.cacheRead, event.cacheWrite]) ?? Int.max
                    let key = DeferredLabelKey(
                        day: day,
                        session: event.session,
                        label: label,
                        isHistoricalPricingDate: isHistoricalPricingDate,
                        contextTokens: contextTokens)
                    if var bucket = self.deferredLabelBuckets[key] {
                        guard bucket.add(event) else {
                            self.hasMissingFields = true
                            continue
                        }
                        self.deferredLabelBuckets[key] = bucket
                    } else {
                        self.deferredLabelBuckets[key] = DeferredLabelBucket(
                            sampleDate: date,
                            inputTokens: event.input,
                            outputTokens: usage.output,
                            cacheReadTokens: usage.cacheRead,
                            cacheCreationTokens: event.cacheWrite,
                            reasoningTokens: usage.reasoning,
                            totalTokens: event.total,
                            requestCount: 1)
                    }
                    self.rows[rowKey] = digest
                    if let responseKey { self.responses[responseKey] = digest }
                    continue
                }
                guard let entry = AntigravityLocalReader.entry(
                    event, models: [:], conflicts: [], calendar: self.calendar, pricing: self.pricing)
                else {
                    self.hasMissingFields = true
                    continue
                }
                self.mergeEntry(entry)
                self.rows[rowKey] = digest
                if let responseKey { self.responses[responseKey] = digest }
            }
        }

        private mutating func mergeEntry(_ entry: CostUsageDailyReport.Entry) {
            if let prior = self.entries[entry.date] {
                guard let merged = AntigravityLocalReader.checkedMergeEntry(prior, entry) else {
                    self.hasMissingFields = true
                    return
                }
                self.entries[entry.date] = merged
            } else {
                self.entries[entry.date] = entry
            }
        }

        mutating func finalize(
            discoveryComplete: Bool,
            statistics: Statistics,
            evidenceIsUnstable: Bool) -> DailyReportResult
        {
            for (key, bucket) in self.deferredLabelBuckets {
                let labelID = LabelIdentity(session: key.session, label: key.label)
                let inherited = self.conflicts.contains(labelID) ? nil : self.models[labelID]
                let model = AntigravityLocalReader.normalizeModelID(inherited ?? "unknown")
                let unattributedZero = bucket.totalTokens == 0 && model == "unknown"
                let cost = self.pricing.flatMap {
                    unattributedZero ? 0 : Self.costUSDForCompactedBucket(
                        pricing: $0,
                        model: model,
                        date: bucket.sampleDate,
                        contextTokens: key.contextTokens,
                        bucket: bucket)
                }
                let entry = CostUsageDailyReport.Entry(
                    date: key.day,
                    inputTokens: bucket.inputTokens,
                    outputTokens: bucket.outputTokens,
                    cacheReadTokens: bucket.cacheReadTokens,
                    cacheCreationTokens: bucket.cacheCreationTokens,
                    reasoningTokens: bucket.reasoningTokens,
                    totalTokens: bucket.totalTokens,
                    requestCount: bucket.requestCount,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: unattributedZero ? [] : [.init(
                        modelName: model,
                        costUSD: cost,
                        totalTokens: bucket.totalTokens,
                        requestCount: bucket.requestCount,
                        inputTokens: bucket.inputTokens,
                        outputTokens: bucket.outputTokens,
                        cacheReadTokens: bucket.cacheReadTokens,
                        cacheCreationTokens: bucket.cacheCreationTokens,
                        reasoningTokens: bucket.reasoningTokens)],
                    unpricedRequestCount: cost == nil ? bucket.requestCount : 0,
                    estimatedRequestCount: cost == nil ? 0 : bucket.requestCount)
                self.mergeEntry(entry)
            }
            self.deferredLabelBuckets.removeAll()

            let isComplete = discoveryComplete
                && self.combinedIsComplete
                && !self.hasMissingFields
                && !self.contradicted
                && statistics.sqliteHandlesOpened == statistics.sqliteHandlesClosed
            if isComplete, !self.containsHistorySource {
                return DailyReportResult(
                    report: .init(data: [], summary: nil),
                    coverage: .unavailable,
                    statistics: statistics)
            }
            let daily = self.entries.values.sorted { $0.date < $1.date }
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
                statistics: statistics,
                evidenceIsContradicted: self.contradicted,
                evidenceIsUnstable: evidenceIsUnstable)
        }

        private static func costUSDForCompactedBucket(
            pricing: CostUsagePricing.ClaudeResolver,
            model: String,
            date: Date,
            contextTokens: Int,
            bucket: DeferredLabelBucket) -> Double?
        {
            let fullUsage = AntigravityProtoReader.ParsedUsage(
                newInput: bucket.inputTokens,
                cacheRead: bucket.cacheReadTokens,
                output: bucket.outputTokens,
                reasoning: bucket.reasoningTokens,
                responseID: nil,
                modelID: nil,
                botID: nil)
            if bucket.requestCount <= 1 || contextTokens == 0 {
                return AntigravityLocalReader.costUSD(
                    pricing: pricing,
                    model: model,
                    date: date,
                    usage: fullUsage,
                    cacheWrite: bucket.cacheCreationTokens)
            }
            func probe(input: Int = 0, cacheRead: Int = 0, output: Int = 0, cacheWrite: Int = 0) -> Double? {
                AntigravityLocalReader.costUSD(
                    pricing: pricing,
                    model: model,
                    date: date,
                    usage: AntigravityProtoReader.ParsedUsage(
                        newInput: input,
                        cacheRead: cacheRead,
                        output: output,
                        reasoning: 0,
                        responseID: nil,
                        modelID: nil,
                        botID: nil),
                    cacheWrite: cacheWrite)
            }
            guard let inputUnit = probe(input: 1),
                  let inputAtContext = probe(input: contextTokens),
                  abs(inputAtContext / Double(contextTokens) - inputUnit) <= 1e-12,
                  let cacheReadUnit = probe(cacheRead: 1),
                  let cacheReadAtContext = probe(cacheRead: contextTokens),
                  abs(cacheReadAtContext / Double(contextTokens) - cacheReadUnit) <= 1e-12,
                  let cacheWriteUnit = probe(cacheWrite: 1),
                  let cacheWriteAtContext = probe(cacheWrite: contextTokens),
                  abs(cacheWriteAtContext / Double(contextTokens) - cacheWriteUnit) <= 1e-12,
                  let outputUnit = probe(output: 1),
                  let outputAtContext = probe(input: contextTokens, output: 1),
                  abs((outputAtContext - inputAtContext) - outputUnit) <= 1e-12
            else {
                return AntigravityLocalReader.costUSD(
                    pricing: pricing,
                    model: model,
                    date: date,
                    usage: fullUsage,
                    cacheWrite: bucket.cacheCreationTokens)
            }
            return Double(bucket.inputTokens) * inputUnit
                + Double(bucket.cacheReadTokens) * cacheReadUnit
                + Double(bucket.cacheCreationTokens) * cacheWriteUnit
                + Double(bucket.outputTokens + bucket.reasoningTokens) * outputUnit
        }

        struct Snapshot: Codable {
            struct ModelEntry: Codable { let session: String; let label: String; let model: String }
            struct ConflictEntry: Codable { let session: String; let label: String }
            struct RowEntry: Codable {
                let sessionID: Int; let row: Int64
                let w0: UInt64; let w1: UInt64; let w2: UInt64; let w3: UInt64
            }

            struct ResponseEntry: Codable {
                let sessionID: Int; let response: String
                let w0: UInt64; let w1: UInt64; let w2: UInt64; let w3: UInt64
            }

            struct DeferredEntry: Codable {
                let key: DeferredLabelKey
                let bucket: DeferredLabelBucket
            }

            let sessionIDs: [String]
            let models: [ModelEntry]
            let conflicts: [ConflictEntry]
            let rows: [RowEntry]
            let responses: [ResponseEntry]
            let entries: [CostUsageDailyReport.Entry]
            let deferredLabelBuckets: [DeferredEntry]
            let containsHistorySource: Bool
            let combinedIsComplete: Bool
            let hasMissingFields: Bool
            let contradicted: Bool
        }

        init(calendar: Calendar, pricing: CostUsagePricing.ClaudeResolver?, snapshot: Snapshot) {
            self.calendar = calendar
            self.pricing = pricing
            for (index, session) in snapshot.sessionIDs.enumerated() {
                self.sessionIDs[session] = index
            }
            for item in snapshot.models {
                self.models[LabelIdentity(session: item.session, label: item.label)] = item.model
            }
            for item in snapshot.conflicts {
                self.conflicts.insert(LabelIdentity(session: item.session, label: item.label))
            }
            for item in snapshot.rows {
                self.rows[CompactRowKey(sessionID: item.sessionID, row: item.row)] = CompactTurnDigest(
                    w0: item.w0,
                    w1: item.w1,
                    w2: item.w2,
                    w3: item.w3)
            }
            for item in snapshot.responses {
                self.responses[CompactResponseKey(sessionID: item.sessionID, response: item.response)] =
                    CompactTurnDigest(
                        w0: item.w0,
                        w1: item.w1,
                        w2: item.w2,
                        w3: item.w3)
            }
            for entry in snapshot.entries {
                self.entries[entry.date] = entry
            }
            for item in snapshot.deferredLabelBuckets {
                self.deferredLabelBuckets[item.key] = item.bucket
            }
            self.containsHistorySource = snapshot.containsHistorySource
            self.combinedIsComplete = snapshot.combinedIsComplete
            self.hasMissingFields = snapshot.hasMissingFields
            self.contradicted = snapshot.contradicted
        }

        func makeSnapshot() -> Snapshot {
            let orderedSessions = self.sessionIDs.sorted { $0.value < $1.value }.map(\.key)
            return Snapshot(
                sessionIDs: orderedSessions,
                models: self.models.map { .init(session: $0.key.session, label: $0.key.label, model: $0.value) },
                conflicts: self.conflicts.map { .init(session: $0.session, label: $0.label) },
                rows: self.rows.map {
                    .init(
                        sessionID: $0.key.sessionID,
                        row: $0.key.row,
                        w0: $0.value.w0,
                        w1: $0.value.w1,
                        w2: $0.value.w2,
                        w3: $0.value.w3)
                },
                responses: self.responses.map {
                    .init(
                        sessionID: $0.key.sessionID,
                        response: $0.key.response,
                        w0: $0.value.w0,
                        w1: $0.value.w1,
                        w2: $0.value.w2,
                        w3: $0.value.w3)
                },
                entries: Array(self.entries.values),
                deferredLabelBuckets: self.deferredLabelBuckets.map { .init(key: $0.key, bucket: $0.value) },
                containsHistorySource: self.containsHistorySource,
                combinedIsComplete: self.combinedIsComplete,
                hasMissingFields: self.hasMissingFields,
                contradicted: self.contradicted)
        }
    }

    private struct ReplayCheckpoint: Codable {
        let version: Int
        let scope: String
        let timeZoneIdentifier: String
        let estimateCost: Bool
        let pricingIdentity: String
        var processedFingerprints: [String: AntigravityLocalScanCache.DatabaseFingerprint]
        var aggregator: StreamingAggregator.Snapshot
    }

    private struct ReplayCheckpointIndex: Codable {
        let version: Int
        let scope: String
        let timeZoneIdentifier: String
        let estimateCost: Bool
        let pricingIdentity: String
        let processedFingerprints: [String: AntigravityLocalScanCache.DatabaseFingerprint]
        let sessionIDs: [String]
        let models: [StreamingAggregator.Snapshot.ModelEntry]
        let conflicts: [StreamingAggregator.Snapshot.ConflictEntry]
        let entries: [CostUsageDailyReport.Entry]
        let deferredLabelBuckets: [StreamingAggregator.Snapshot.DeferredEntry]
        let containsHistorySource: Bool
        let combinedIsComplete: Bool
        let hasMissingFields: Bool
        let contradicted: Bool
        let chunkCount: Int
    }

    private struct ReplayCheckpointChunk: Codable {
        let rows: [StreamingAggregator.Snapshot.RowEntry]
        let responses: [StreamingAggregator.Snapshot.ResponseEntry]
    }

    private struct IncrementalCacheState {
        let scope: String
        var activeKeys: Set<String>
        var updatedEntries: [String: AntigravityLocalScanCache.CachedDatabaseEntry] = [:]
        var retainedComplete: AntigravityLocalScanCache.RetainedCompleteReport?
        let legacyDatabases: [String: AntigravityLocalScanCache.CachedDatabaseEntry]?
    }

    static func makeIncrementalDailyReportWithStatus(_ request: IncrementalScanRequest) throws -> DailyReportResult {
        let scope = CostUsageFetcher.antigravityHistoryScope(
            environment: request.context.environment,
            additionalProfileHomes: request.context.additionalProfileHomes)
        let indexSnapshot = AntigravityLocalScanCacheIO.loadIndex(cacheRoot: request.scanCacheRoot, scope: scope)
        var cacheState = IncrementalCacheState(
            scope: scope,
            activeKeys: indexSnapshot.indexedKeys,
            retainedComplete: indexSnapshot.retainedComplete,
            legacyDatabases: indexSnapshot.legacyDatabases)

        let databases: Discovery
        do {
            databases = try self.discover(
                roots: request.context.databaseRoots,
                extension: "db",
                budget: request.budget,
                enforceDatabaseCap: false)
        } catch ScanFailure.exhausted, ScanFailure.schemaExhausted {
            return self.retainedOrPartialResult(
                retainedComplete: cacheState.retainedComplete,
                fallbackReport: .init(data: [], summary: nil),
                options: RetainedReportOptions(
                    calendar: request.calendar,
                    estimateCost: request.estimateCost,
                    statistics: request.budget.statistics,
                    catchUpPending: false,
                    batchMadeProgress: false,
                    allowRetained: true))
        }

        if databases.paths.isEmpty, databases.isComplete {
            return try self.incrementalJSONLFallback(request: request, cacheState: &cacheState)
        }

        let replayStarted = request.budget.clock()
        let currentPricingIdentity = self.pricingIdentity(for: request)
        var checkpoint = self.loadReplayCheckpoint(
            request: request,
            scope: scope,
            pricingIdentity: currentPricingIdentity)
        var outcome = try self.partitionDatabases(
            discovery: databases,
            request: request,
            replayStarted: replayStarted,
            checkpoint: &checkpoint,
            cacheState: &cacheState)
        request.budget.excludeElapsedSince(replayStarted)
        var processedFingerprints = checkpoint?.processedFingerprints ?? [:]
        if !outcome.state.batchExhausted {
            try self.scanPendingDatabases(
                outcome.pending,
                cacheState: &cacheState,
                state: &outcome.state,
                processedFingerprints: &processedFingerprints,
                budget: request.budget)
        }

        if outcome.state.evidenceIsUnstable {
            if outcome.state.cacheDirty {
                _ = try self.persistCacheIfAllowed(cacheState, request: request)
            }
            AntigravityLocalScanCacheIO.removeReplayCheckpoint(cacheRoot: request.scanCacheRoot, scope: scope)
            return DailyReportResult(
                report: .init(data: [], summary: nil),
                coverage: .partial,
                statistics: request.budget.statistics,
                evidenceIsUnstable: true)
        }

        let allDatabasesAccounted = databases.isComplete
            && !outcome.state.batchExhausted
            && !outcome.state.schemaIncomplete
            && !outcome.state.hadIncompleteSource
            && outcome.state.aggregator.combinedIsComplete
            && request.budget.statistics.sqliteHandlesOpened == request.budget.statistics.sqliteHandlesClosed

        let checkpointSnapshot = outcome.state.batchExhausted ? outcome.state.aggregator.makeSnapshot() : nil
        let aggregated = outcome.state.aggregator.finalize(
            discoveryComplete: allDatabasesAccounted,
            statistics: request.budget.statistics,
            evidenceIsUnstable: outcome.state.evidenceIsUnstable)

        if aggregated.evidenceIsContradicted {
            if outcome.state.cacheDirty {
                _ = try self.persistCacheIfAllowed(cacheState, request: request)
            }
            AntigravityLocalScanCacheIO.removeReplayCheckpoint(cacheRoot: request.scanCacheRoot, scope: scope)
            return DailyReportResult(
                report: aggregated.report,
                coverage: .partial,
                statistics: request.budget.statistics,
                evidenceIsContradicted: true,
                evidenceIsUnstable: aggregated.evidenceIsUnstable)
        }

        if allDatabasesAccounted, aggregated.coverage == .unavailable {
            if cacheState.retainedComplete != nil {
                cacheState.retainedComplete = nil
                outcome.state.cacheDirty = true
            }
            if outcome.state.cacheDirty {
                _ = try self.persistCacheIfAllowed(cacheState, request: request)
            }
            AntigravityLocalScanCacheIO.removeReplayCheckpoint(cacheRoot: request.scanCacheRoot, scope: scope)
            return DailyReportResult(
                report: aggregated.report,
                coverage: .unavailable,
                statistics: request.budget.statistics)
        }

        if allDatabasesAccounted, aggregated.isComplete {
            cacheState.retainedComplete = AntigravityLocalScanCache.RetainedCompleteReport(
                updatedAtUnixMs: Int64((request.now.timeIntervalSince1970 * 1000).rounded()),
                timeZoneIdentifier: request.calendar.timeZone.identifier,
                estimateCost: request.estimateCost,
                report: aggregated.report)
            let persisted = try self.persistCacheIfAllowed(cacheState, request: request)
            AntigravityLocalScanCacheIO.removeReplayCheckpoint(cacheRoot: request.scanCacheRoot, scope: scope)
            return DailyReportResult(
                report: aggregated.report,
                coverage: .complete,
                statistics: request.budget.statistics,
                catchUpPending: false,
                batchMadeProgress: outcome.state.batchMadeProgress && persisted)
        }

        let persisted = try outcome.state.cacheDirty
            ? (self.persistCacheIfAllowed(cacheState, request: request))
            : false

        var checkpointSaved = false
        if outcome.state.batchExhausted,
           let checkpointSnapshot,
           !processedFingerprints.isEmpty
        {
            checkpointSaved = self.saveReplayCheckpoint(
                ReplayCheckpoint(
                    version: AntigravityLocalScanCacheIO.cacheVersion,
                    scope: scope,
                    timeZoneIdentifier: request.calendar.timeZone.identifier,
                    estimateCost: request.estimateCost,
                    pricingIdentity: currentPricingIdentity,
                    processedFingerprints: processedFingerprints,
                    aggregator: checkpointSnapshot),
                request: request)
        } else {
            AntigravityLocalScanCacheIO.removeReplayCheckpoint(cacheRoot: request.scanCacheRoot, scope: scope)
        }

        return self.retainedOrPartialResult(
            retainedComplete: cacheState.retainedComplete,
            fallbackReport: aggregated.report,
            options: RetainedReportOptions(
                calendar: request.calendar,
                estimateCost: request.estimateCost,
                statistics: request.budget.statistics,
                catchUpPending: outcome.state.batchExhausted,
                batchMadeProgress: (outcome.state.replayMadeProgress && checkpointSaved)
                    || ((outcome.state.batchMadeProgress || outcome.state.cacheDirty) && persisted),
                allowRetained: outcome.state.batchExhausted))
    }

    private static func incrementalJSONLFallback(
        request: IncrementalScanRequest,
        cacheState: inout IncrementalCacheState) throws -> DailyReportResult
    {
        var cacheDirty = !cacheState.activeKeys.isEmpty
        if cacheDirty {
            cacheState.activeKeys.removeAll()
            cacheState.updatedEntries.removeAll()
        }
        do {
            let jsonl = try self.discover(
                roots: [request.context.cacheRoot],
                extension: "jsonl",
                budget: request.budget)
            guard !jsonl.paths.isEmpty || !jsonl.isComplete else {
                if cacheState.retainedComplete != nil {
                    cacheState.retainedComplete = nil
                    cacheDirty = true
                }
                if cacheDirty {
                    _ = self.persistCache(cacheState, cacheRoot: request.scanCacheRoot)
                }
                return DailyReportResult(
                    report: .init(data: [], summary: nil),
                    coverage: .unavailable,
                    statistics: request.budget.statistics)
            }
            let source = try self.readJSONL(jsonl.paths, budget: request.budget)
            let result = try self.aggregate(
                source,
                discoveryComplete: jsonl.isComplete,
                calendar: request.calendar,
                budget: request.budget,
                pricing: request.pricing)
            if result.isComplete, !result.evidenceIsContradicted, !result.evidenceIsUnstable {
                cacheState.retainedComplete = AntigravityLocalScanCache.RetainedCompleteReport(
                    updatedAtUnixMs: Int64((request.now.timeIntervalSince1970 * 1000).rounded()),
                    timeZoneIdentifier: request.calendar.timeZone.identifier,
                    estimateCost: request.estimateCost,
                    report: result.report)
                cacheDirty = true
            }
            if cacheDirty {
                _ = self.persistCache(cacheState, cacheRoot: request.scanCacheRoot)
            }
            return result
        } catch ScanFailure.exhausted, ScanFailure.schemaExhausted {
            if cacheDirty {
                _ = self.persistCache(cacheState, cacheRoot: request.scanCacheRoot)
            }
            return self.retainedOrPartialResult(
                retainedComplete: cacheState.retainedComplete,
                fallbackReport: .init(data: [], summary: nil),
                options: RetainedReportOptions(
                    calendar: request.calendar,
                    estimateCost: request.estimateCost,
                    statistics: request.budget.statistics,
                    catchUpPending: false,
                    batchMadeProgress: false,
                    allowRetained: true))
        }
    }

    private static func pricingIdentity(for request: IncrementalScanRequest) -> String {
        guard request.estimateCost, let resolver = request.pricing else { return "none" }
        let catalog = resolver.prepareCatalog()
        let artifact = ModelsDevCacheArtifact(
            version: 1,
            fetchedAt: Date(timeIntervalSince1970: 0),
            catalog: catalog)
        return CostUsagePricingKey.codex(
            modelsDevArtifact: artifact,
            formulaVersion: 1,
            modelsDevProviderIDs: Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs))
    }

    private static func loadReplayCheckpoint(
        request: IncrementalScanRequest,
        scope: String,
        pricingIdentity: String) -> ReplayCheckpoint?
    {
        guard let data = AntigravityLocalScanCacheIO.loadReplayCheckpointData(
            cacheRoot: request.scanCacheRoot,
            scope: scope),
            let index = try? JSONDecoder().decode(ReplayCheckpointIndex.self, from: data),
            index.version == AntigravityLocalScanCacheIO.cacheVersion,
            index.scope == scope,
            index.timeZoneIdentifier == request.calendar.timeZone.identifier,
            index.estimateCost == request.estimateCost,
            index.pricingIdentity == pricingIdentity,
            index.chunkCount >= 0
        else { return nil }

        let decoder = JSONDecoder()
        var rows: [StreamingAggregator.Snapshot.RowEntry] = []
        var responses: [StreamingAggregator.Snapshot.ResponseEntry] = []
        for chunkIndex in 0..<index.chunkCount {
            guard let chunkData = AntigravityLocalScanCacheIO.loadReplayChunkData(
                cacheRoot: request.scanCacheRoot,
                scope: scope,
                index: chunkIndex),
                let chunk = try? decoder.decode(ReplayCheckpointChunk.self, from: chunkData)
            else { return nil }
            rows.append(contentsOf: chunk.rows)
            responses.append(contentsOf: chunk.responses)
        }

        let snapshot = StreamingAggregator.Snapshot(
            sessionIDs: index.sessionIDs,
            models: index.models,
            conflicts: index.conflicts,
            rows: rows,
            responses: responses,
            entries: index.entries,
            deferredLabelBuckets: index.deferredLabelBuckets,
            containsHistorySource: index.containsHistorySource,
            combinedIsComplete: index.combinedIsComplete,
            hasMissingFields: index.hasMissingFields,
            contradicted: index.contradicted)
        return ReplayCheckpoint(
            version: index.version,
            scope: index.scope,
            timeZoneIdentifier: index.timeZoneIdentifier,
            estimateCost: index.estimateCost,
            pricingIdentity: index.pricingIdentity,
            processedFingerprints: index.processedFingerprints,
            aggregator: snapshot)
    }

    private static func saveReplayCheckpoint(_ checkpoint: ReplayCheckpoint, request: IncrementalScanRequest) -> Bool {
        let chunkLimit = 50000
        let rows = checkpoint.aggregator.rows
        let responses = checkpoint.aggregator.responses
        let rowChunks = stride(from: 0, to: rows.count, by: chunkLimit).map {
            Array(rows[$0..<min($0 + chunkLimit, rows.count)])
        }
        let responseChunks = stride(from: 0, to: responses.count, by: chunkLimit).map {
            Array(responses[$0..<min($0 + chunkLimit, responses.count)])
        }
        let chunkCount = max(rowChunks.count, responseChunks.count)
        let encoder = JSONEncoder()
        var chunksData: [Data] = []
        chunksData.reserveCapacity(chunkCount)
        for index in 0..<chunkCount {
            let chunk = ReplayCheckpointChunk(
                rows: index < rowChunks.count ? rowChunks[index] : [],
                responses: index < responseChunks.count ? responseChunks[index] : [])
            guard let encoded = try? encoder.encode(chunk) else { return false }
            chunksData.append(encoded)
        }
        let indexPayload = ReplayCheckpointIndex(
            version: checkpoint.version,
            scope: checkpoint.scope,
            timeZoneIdentifier: checkpoint.timeZoneIdentifier,
            estimateCost: checkpoint.estimateCost,
            pricingIdentity: checkpoint.pricingIdentity,
            processedFingerprints: checkpoint.processedFingerprints,
            sessionIDs: checkpoint.aggregator.sessionIDs,
            models: checkpoint.aggregator.models,
            conflicts: checkpoint.aggregator.conflicts,
            entries: checkpoint.aggregator.entries,
            deferredLabelBuckets: checkpoint.aggregator.deferredLabelBuckets,
            containsHistorySource: checkpoint.aggregator.containsHistorySource,
            combinedIsComplete: checkpoint.aggregator.combinedIsComplete,
            hasMissingFields: checkpoint.aggregator.hasMissingFields,
            contradicted: checkpoint.aggregator.contradicted,
            chunkCount: chunkCount)
        guard let indexData = try? encoder.encode(indexPayload) else { return false }
        return AntigravityLocalScanCacheIO.saveShardedReplayCheckpoint(
            indexData: indexData,
            chunksData: chunksData,
            cacheRoot: request.scanCacheRoot,
            scope: checkpoint.scope)
    }

    private static func partitionDatabases(
        discovery: Discovery,
        request: IncrementalScanRequest,
        replayStarted: TimeInterval,
        checkpoint: inout ReplayCheckpoint?,
        cacheState: inout IncrementalCacheState) throws -> (pending: [PendingDatabase], state: BatchScanOutcome)
    {
        let paths = discovery.paths
        let discoveryComplete = discovery.isComplete
        var staleCacheDirty = false
        if discoveryComplete {
            let discoveredKeys = Set(paths.map(\.standardizedFileURL.path))
            let staleKeys = cacheState.activeKeys.filter { !discoveredKeys.contains($0) }
            if !staleKeys.isEmpty {
                for key in staleKeys {
                    cacheState.activeKeys.remove(key)
                }
                staleCacheDirty = true
            }
            if let existing = checkpoint,
               existing.processedFingerprints.keys.contains(where: { !discoveredKeys.contains($0) })
            {
                checkpoint = nil
            }
        }

        if let existing = checkpoint {
            let valid = existing.processedFingerprints.allSatisfy { key, savedFingerprint in
                AntigravityLocalScanCache.DatabaseFingerprint.current(for: URL(fileURLWithPath: key))
                    == savedFingerprint
            }
            if !valid {
                checkpoint = nil
            }
        }

        var state = BatchScanOutcome(
            aggregator: checkpoint.map {
                StreamingAggregator(calendar: request.calendar, pricing: request.pricing, snapshot: $0.aggregator)
            } ?? StreamingAggregator(calendar: request.calendar, pricing: request.pricing),
            cacheDirty: staleCacheDirty)
        var processed = checkpoint?.processedFingerprints ?? [:]
        var pending: [PendingDatabase] = []
        var attemptedCachedFragments = 0
        var attemptedCachedBytes = 0
        for url in paths {
            try request.budget.cancellation()
            let key = url.standardizedFileURL.path
            if processed[key] != nil {
                continue
            }
            let fingerprint = AntigravityLocalScanCache.DatabaseFingerprint.current(for: url)
            if let fingerprint, cacheState.activeKeys.contains(key) {
                let fragmentSize = cacheState.legacyDatabases == nil
                    ? AntigravityLocalScanCacheIO.fragmentFileSize(
                        cacheRoot: request.scanCacheRoot,
                        scope: cacheState.scope,
                        key: key)
                    : nil
                if attemptedCachedFragments > 0 {
                    let replayDurationExceeded = request.budget.limits.duration > 0
                        && request.budget.clock() - replayStarted >= request.budget.limits.duration
                    let replayBytesExceeded = (fragmentSize ?? 0) + attemptedCachedBytes > request.maximumReplayBytes
                    if replayDurationExceeded || replayBytesExceeded {
                        state.batchExhausted = true
                        break
                    }
                }
                attemptedCachedFragments += 1
                attemptedCachedBytes += fragmentSize ?? 0
                var cacheHit = false
                try autoreleasepool {
                    let cached = cacheState.legacyDatabases?[key] ?? AntigravityLocalScanCacheIO.loadFragment(
                        cacheRoot: request.scanCacheRoot,
                        scope: cacheState.scope,
                        key: key)
                    if let cached, cached.fingerprint == fingerprint {
                        let events = cached.events.compactMap { $0.makeEvent() }
                        if events.count == cached.events.count {
                            try state.aggregator.ingest(events)
                            state.aggregator.containsHistorySource = state.aggregator.containsHistorySource
                                || cached.containsHistorySource
                            cacheHit = true
                            processed[key] = fingerprint
                            state.replayMadeProgress = true
                            if cacheState.legacyDatabases != nil {
                                cacheState.updatedEntries[key] = cached
                                state.cacheDirty = true
                            }
                        }
                    }
                }
                if cacheHit {
                    continue
                }
                cacheState.activeKeys.remove(key)
                state.cacheDirty = true
            }
            pending.append(PendingDatabase(url: url, key: key, fingerprintBefore: fingerprint))
        }

        if checkpoint == nil {
            checkpoint = ReplayCheckpoint(
                version: AntigravityLocalScanCacheIO.cacheVersion,
                scope: cacheState.scope,
                timeZoneIdentifier: request.calendar.timeZone.identifier,
                estimateCost: request.estimateCost,
                pricingIdentity: self.pricingIdentity(for: request),
                processedFingerprints: processed,
                aggregator: state.aggregator.makeSnapshot())
        } else {
            checkpoint?.processedFingerprints = processed
        }

        // Scan newest-modified conversations (main DB or active WAL) first so recent days land in the earliest batch.
        pending.sort { lhs, rhs in
            let lhsStamp = lhs.fingerprintBefore?.latestModifiedTimestamp
            let rhsStamp = rhs.fingerprintBefore?.latestModifiedTimestamp
            let lhsSec = lhsStamp?.seconds ?? Int64.min
            let rhsSec = rhsStamp?.seconds ?? Int64.min
            if lhsSec != rhsSec { return lhsSec > rhsSec }
            let lhsNsec = lhsStamp?.nanoseconds ?? Int64.min
            let rhsNsec = rhsStamp?.nanoseconds ?? Int64.min
            if lhsNsec != rhsNsec { return lhsNsec > rhsNsec }
            return lhs.key < rhs.key
        }
        return (pending, state)
    }

    private static func persistCache(_ cacheState: IncrementalCacheState, cacheRoot: URL) -> Bool {
        AntigravityLocalScanCacheIO.saveIncremental(
            scope: cacheState.scope,
            activeKeys: cacheState.activeKeys,
            updatedEntries: cacheState.updatedEntries,
            retainedComplete: cacheState.retainedComplete,
            cacheRoot: cacheRoot)
    }

    private static func persistCacheIfAllowed(
        _ cacheState: IncrementalCacheState,
        request: IncrementalScanRequest) throws -> Bool
    {
        try request.budget.cancellation()
        return self.persistCache(cacheState, cacheRoot: request.scanCacheRoot)
    }

    private static func scanPendingDatabases(
        _ pending: [PendingDatabase],
        cacheState: inout IncrementalCacheState,
        state: inout BatchScanOutcome,
        processedFingerprints: inout [String: AntigravityLocalScanCache.DatabaseFingerprint],
        budget: Budget) throws
    {
        for item in pending {
            do {
                try budget.check()
            } catch ScanFailure.exhausted {
                state.batchExhausted = true
                break
            }
            guard budget.statistics.files < budget.limits.databases else {
                state.batchExhausted = true
                break
            }
            budget.statistics.files += 1
            budget.beginDatabase()

            let source: SourceResult
            do {
                source = try self.readDatabase(item.url, budget: budget)
            } catch ScanFailure.schemaExhausted {
                state.schemaIncomplete = true
                continue
            } catch ScanFailure.exhausted {
                state.batchExhausted = true
                break
            }

            if source.evidenceIsUnstable {
                state.evidenceIsUnstable = true
                return
            }

            let fingerprintAfter = AntigravityLocalScanCache.DatabaseFingerprint.current(for: item.url)
            if source.isComplete,
               let before = item.fingerprintBefore,
               before == fingerprintAfter
            {
                let cachedEvents = source.events.compactMap { AntigravityLocalScanCache.CachedEvent(event: $0) }
                if cachedEvents.count == source.events.count {
                    cacheState.activeKeys.insert(item.key)
                    cacheState.updatedEntries[item.key] = .init(
                        fingerprint: before,
                        containsHistorySource: source.containsHistorySource,
                        events: cachedEvents)
                    processedFingerprints[item.key] = before
                    state.cacheDirty = true
                    state.batchMadeProgress = true
                }
            } else {
                state.hadIncompleteSource = true
            }

            try state.aggregator.ingest(source.events)
            state.aggregator.containsHistorySource = state.aggregator.containsHistorySource
                || source.containsHistorySource
            state.aggregator.combinedIsComplete = state.aggregator.combinedIsComplete && source.isComplete
        }
    }

    private static func retainedOrPartialResult(
        retainedComplete: AntigravityLocalScanCache.RetainedCompleteReport?,
        fallbackReport: CostUsageDailyReport,
        options: RetainedReportOptions) -> DailyReportResult
    {
        if options.allowRetained,
           let retained = retainedComplete,
           retained.timeZoneIdentifier == options.calendar.timeZone.identifier,
           retained.estimateCost == options.estimateCost,
           !retained.report.data.isEmpty
        {
            let retainedAt = Date(timeIntervalSince1970: TimeInterval(retained.updatedAtUnixMs) / 1000)
            return DailyReportResult(
                report: retained.report,
                coverage: .partial,
                statistics: options.statistics,
                catchUpPending: options.catchUpPending,
                batchMadeProgress: options.batchMadeProgress,
                retainedUpdatedAt: retainedAt)
        }
        return DailyReportResult(
            report: fallbackReport,
            coverage: .partial,
            statistics: options.statistics,
            catchUpPending: options.catchUpPending,
            batchMadeProgress: options.batchMadeProgress)
    }
}
