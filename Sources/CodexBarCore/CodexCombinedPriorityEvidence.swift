import Foundation

/// Request-owned pricing evidence. Never put local turn IDs in the scanner's global trace map:
/// another host may use the same turn ID for an independent session.
struct CodexCombinedPriorityEvidence {
    typealias Row = CostUsageScanner.CodexUsageRow
    typealias Turn = CostUsageScanner.CodexPriorityTurnMetadata

    struct ScopedTurn: Hashable {
        let session: String
        let turn: String
    }

    struct RowKey: Hashable {
        let session: String
        let event: Int
        let timestamp: Int64
        let turn: String?
        let model: String
        let input: Int
        let cached: Int
        let output: Int
        let reasoning: Int?
        let knownCost: Int64?

        init(session: String, row: Row) throws {
            guard let event = row.eventIndex, let timestamp = row.timestampUnixMs else {
                throw CodexCombinedCostError.pricingEvidence
            }
            self.session = session
            self.event = event
            self.timestamp = timestamp
            self.turn = row.turnID
            self.model = row.model
            self.input = row.input
            self.cached = row.cached
            self.output = row.output
            self.reasoning = row.reasoning
            self.knownCost = row.knownCostNanos
        }
    }

    var retainedModels: [RowKey: String] = [:]
    var retainedSessionsByPath: [String: String] = [:]
    var turnsBySession: [String: [String: Turn]] = [:]
    var requiredTraceTurns = Set<ScopedTurn>()

    mutating func retain(
        file: CostUsageStoreFile,
        rows: [Row],
        aggregates: [CostUsageStoreDayAggregate],
        range: CostUsageScanner.CostUsageDayRange) throws
    {
        let priority = rows.filter { $0.pricingMode == "priority" }
        // A count alone cannot establish which rows were Fast. Check all token classes, not just their sum.
        let groups = Dictionary(grouping: priority) { CostUsageScanner.CodexDayModelKey(day: $0.day, model: $0.model) }
        for aggregate in aggregates {
            let matching = groups[.init(day: aggregate.day, model: aggregate.model)] ?? []
            let estimated = matching.filter { $0.knownCostNanos == nil }
            let input = try Self.sum(estimated.map(\.input))
            let cached = try Self.sum(estimated.map(\.cached))
            let output = try Self.sum(estimated.map(\.output))
            let total = try Self.sum(matching.flatMap { [$0.input, $0.output] })
            guard Int64(input) == aggregate.priorityInputTokens,
                  Int64(cached) == aggregate.priorityCachedTokens,
                  Int64(output) == aggregate.priorityOutputTokens,
                  Int64(total) == aggregate.priorityTokens
            else { throw CodexCombinedCostError.pricingEvidence }
        }
        for row in priority {
            guard let timestamp = row.timestampUnixMs else { throw CodexCombinedCostError.pricingEvidence }
            let day = CostUsageLocalDay.key(
                from: Date(timeIntervalSince1970: Double(timestamp) / 1000), calendar: range.calendar)
            guard day >= range.sinceKey, day <= range.untilKey else { continue }
            guard let session = file.sessionID, !session.isEmpty else {
                throw CodexCombinedCostError.pricingEvidence
            }
            let key = try RowKey(session: session, row: row)
            let model = row.pricingModel ?? row.model
            if let previous = self.retainedModels[key], previous != model {
                throw CodexCombinedCostError.pricingEvidence
            }
            self.retainedModels[key] = model
            self.retainedSessionsByPath[URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path] = session
        }
    }

    mutating func resolveTrace(
        at url: URL?,
        localTurns: [String: Set<String>],
        since: Date?,
        until: Date?,
        calendar: Calendar) throws
    {
        guard let url, !localTurns.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return }
        #if canImport(SQLite3)
        let resolution = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: url, expectExistingDatabase: true)
        guard !resolution.validationPending else { throw CodexCombinedCostError.pricingEvidence }
        guard let cursor = CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: url) else {
            throw CodexCombinedCostError.pricingEvidence
        }
        var cursorTurns = cursor.turns
        for (turnID, models) in cursor.priorityCompletedModelsByTurnID {
            cursorTurns[turnID]?.model = models.max { $0.key < $1.key }?.value
        }
        // A concurrent ordinary refresh may advance the shared memo between the two reads.
        guard cursorTurns == resolution.turns else { throw CodexCombinedCostError.pricingEvidence }
        let sources = cursor.requestSourcesByTurnID
        for (turnID, requests) in sources where localTurns.values.contains(where: { $0.contains(turnID) }) {
            let threads = Set(requests.values.compactMap(\.threadID))
            guard threads.count <= 1 else { throw CodexCombinedCostError.pricingEvidence }
            if requests.values.contains(where: { $0.threadID == nil }) {
                let owners = localTurns.filter { $0.value.contains(turnID) }.keys
                guard owners.count == 1, let owner = owners.first,
                      threads.allSatisfy({ $0 == owner }) else { throw CodexCombinedCostError.pricingEvidence }
            }
        }
        for turn in resolution.turns.values {
            let candidates = localTurns.filter { session, turns in
                turns.contains(turn.turnID) && (turn.threadID == nil || turn.threadID == session)
            }.keys
            if candidates.isEmpty {
                // Unrelated traces do not price remote records. Keep rejecting in-window evidence for a
                // local session whose usage cannot be associated with the trace's turn identity.
                if let thread = turn.threadID, localTurns[thread] != nil,
                   Self.traceMayBeInWindow(turn, since: since, until: until, calendar: calendar)
                { throw CodexCombinedCostError.pricingEvidence }
                continue
            }
            guard candidates.count == 1, let session = candidates.first else {
                throw CodexCombinedCostError.pricingEvidence
            }
            let requests = sources[turn.turnID] ?? [:]
            guard !requests.isEmpty, requests.values.allSatisfy({ $0.threadID == nil || $0.threadID == session }) else {
                throw CodexCombinedCostError.pricingEvidence
            }
            try Self.validateCompletions(
                url: url,
                models: cursor.priorityCompletedModelsByTurnID[turn.turnID] ?? [:],
                turn: turn,
                session: session,
                requestModels: Set(requests.values.compactMap(\.model)))
            // Scope by usage identity, not request date: a turn can start before midnight/the window.
            self.turnsBySession[session, default: [:]][turn.turnID] = turn
            if Self.traceMayBeInWindow(turn, since: since, until: until, calendar: calendar) {
                self.requiredTraceTurns.insert(.init(session: session, turn: turn.turnID))
            }
        }
        #else
        throw CodexCombinedCostError.pricingEvidence
        #endif
    }

    func applying(
        to cache: CostUsageCache,
        range: CostUsageScanner.CostUsageDayRange,
        checkCancellation: () throws -> Void) throws -> CostUsageCache
    {
        var result = cache
        var remaining = Set(self.retainedModels.keys)
        var remainingTurns = self.requiredTraceTurns
        for (path, usage) in cache.files {
            try checkCancellation()
            guard let session = usage.sessionId else { continue }
            var rows = usage.codexRows ?? []
            for index in rows.indices {
                try checkCancellation()
                let key = try RowKey(session: session, row: rows[index])
                if let model = self.retainedModels[key] {
                    rows[index].pricingMode = "priority"
                    rows[index].pricingModel = model
                    remaining.remove(key)
                }
                if let turnID = rows[index].turnID, let turn = self.turnsBySession[session]?[turnID] {
                    // A submission can prove the tier without naming a model. It must not erase a
                    // previously established Fast model with the rollout's less-specific model name.
                    if let model = turn.model, CostUsagePricing.codexAPIFastMultiplier(model: model) != nil {
                        if let retained = self.retainedModels[key],
                           CostUsagePricing.normalizeCodexModel(retained) != CostUsagePricing.normalizeCodexModel(model)
                        { throw CodexCombinedCostError.pricingEvidence }
                        rows[index].pricingModel = model
                    }
                    rows[index].pricingMode = "priority"
                    remainingTurns.remove(.init(session: session, turn: turnID))
                }
            }
            var updated = usage
            updated.codexRows = rows
            let modes = CostUsageScanner.codexModeTokenMaps(rows: rows, range: range, priorityTurns: [:])
            updated.codexStandardTokens = modes.standard
            updated.codexPriorityTokens = modes.priority
            result.files[path] = updated
        }
        guard remaining.isEmpty, remainingTurns.isEmpty else { throw CodexCombinedCostError.pricingEvidence }
        return result
    }

    private static func sum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw CodexCombinedCostError.pricingEvidence }
            return sum
        }
    }

    private static func traceMayBeInWindow(
        _ turn: Turn, since: Date?, until: Date?, calendar: Calendar) -> Bool
    {
        guard let timestamp = turn.timestamp,
              let date = ISO8601DateParser.parse(timestamp)
              ?? Double(timestamp).map({ Date(timeIntervalSince1970: $0) }) else { return true }
        if let since, date < since { return false }
        if let until, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: until)),
           date >= end { return false }
        return true
    }
}
