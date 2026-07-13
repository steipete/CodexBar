import Foundation

/// Experimental accounting model for Codex rollout families.
///
/// Rollout files are overlapping physical views of a logical lineage. The ledger builds the
/// transitive lineage first, then admits each complete token observation once per lineage.
/// It intentionally does not participate in production cost totals yet.
enum CodexLineageLedger {
    struct Totals: Equatable, Hashable, Sendable {
        var input: Int
        var cached: Int
        var output: Int

        static let zero = Self(input: 0, cached: 0, output: 0)

        mutating func add(_ other: Self) {
            self.input += other.input
            self.cached += other.cached
            self.output += other.output
        }
    }

    struct Observation: Equatable, Sendable {
        let timestamp: String
        let model: String
        let last: Totals
        let total: Totals

        init(timestamp: String, model: String = CostUsagePricing.codexUnattributedModel, last: Totals, total: Totals) {
            self.timestamp = timestamp
            self.model = CostUsagePricing.normalizeCodexModel(model)
            self.last = last
            self.total = total
        }
    }

    struct Document: Equatable, Sendable {
        /// Canonical owner from the rollout filename when available.
        let ownerID: String
        /// Session identity persisted in metadata. Fork copies may retain an ancestor identity.
        let metadataSessionID: String?
        let parentSessionID: String?
        let observations: [Observation]
    }

    struct Report: Equatable, Sendable {
        let utcDays: [String: Totals]
        let localDays: [String: Totals]
        let utcRows: [DailyRow]
        let localRows: [DailyRow]
        let componentCount: Int
        let acceptedObservationCount: Int
        let duplicateObservationCount: Int
    }

    struct DailyRow: Equatable, Sendable {
        let day: String
        let model: String
        let totals: Totals
        let costUSD: Double?

        var isPriced: Bool {
            self.costUSD != nil
        }
    }

    enum LedgerError: Error, Equatable {
        case emptyOwnerID
        case invalidTimestamp(String)
    }

    static func reconcile(
        documents: [Document],
        localTimeZone: TimeZone,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Report
    {
        var graph = DisjointSet()
        for document in documents {
            try checkCancellation?()
            guard !document.ownerID.isEmpty else { throw LedgerError.emptyOwnerID }
            graph.insert(document.ownerID)
            if let metadataSessionID = Self.nonEmpty(document.metadataSessionID) {
                graph.union(document.ownerID, metadataSessionID)
            }
            if let parentSessionID = Self.nonEmpty(document.parentSessionID) {
                graph.union(document.ownerID, parentSessionID)
            }
        }

        var acceptedByComponent: [String: [Fingerprint: AcceptedObservation]] = [:]
        var physicalObservationCount = 0
        for document in documents {
            try checkCancellation?()
            let componentID = graph.find(document.ownerID)
            var accepted = acceptedByComponent[componentID] ?? [:]
            for observation in document.observations {
                try checkCancellation?()
                physicalObservationCount += 1
                let date = try Self.date(from: observation.timestamp)
                let fingerprint = Fingerprint(last: observation.last, total: observation.total)
                if let existing = accepted[fingerprint] {
                    if existing.date < date {
                        continue
                    }
                    if existing.date == date,
                       !Self.shouldPreferModel(observation.model, over: existing.model)
                    {
                        continue
                    }
                }
                accepted[fingerprint] = AcceptedObservation(
                    date: date,
                    model: observation.model,
                    last: observation.last)
            }
            acceptedByComponent[componentID] = accepted
        }

        var utcDays: [String: Totals] = [:]
        var localDays: [String: Totals] = [:]
        var utcRows: [DailyRowKey: DailyRowValue] = [:]
        var localRows: [DailyRowKey: DailyRowValue] = [:]
        var acceptedObservationCount = 0
        for accepted in acceptedByComponent.values {
            try checkCancellation?()
            acceptedObservationCount += accepted.count
            for observation in accepted.values {
                try checkCancellation?()
                Self.add(observation.last, on: observation.date, timeZone: .gmt, to: &utcDays)
                Self.add(observation.last, on: observation.date, timeZone: localTimeZone, to: &localDays)
                Self.addRow(observation, timeZone: .gmt, to: &utcRows)
                Self.addRow(observation, timeZone: localTimeZone, to: &localRows)
            }
        }

        return Report(
            utcDays: utcDays,
            localDays: localDays,
            utcRows: Self.dailyRows(from: utcRows),
            localRows: Self.dailyRows(from: localRows),
            componentCount: Set(documents.map { graph.find($0.ownerID) }).count,
            acceptedObservationCount: acceptedObservationCount,
            duplicateObservationCount: physicalObservationCount - acceptedObservationCount)
    }

    private struct Fingerprint: Equatable, Hashable {
        let last: Totals
        let total: Totals
    }

    private struct AcceptedObservation {
        let date: Date
        let model: String
        let last: Totals
    }

    private struct DailyRowKey: Hashable {
        let day: String
        let model: String
    }

    private struct DailyRowValue {
        var totals: Totals = .zero
        var costUSD = 0.0
        var isPriced = true
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Duplicate copies can carry different model evidence. Keep the earliest physical copy,
    /// then resolve equal-time ties deterministically while preferring attributable evidence.
    private static func shouldPreferModel(_ candidate: String, over existing: String) -> Bool {
        let candidateIsUnknown = CostUsagePricing.isCodexUnattributedModel(candidate)
        let existingIsUnknown = CostUsagePricing.isCodexUnattributedModel(existing)
        if candidateIsUnknown != existingIsUnknown {
            return !candidateIsUnknown
        }
        return candidate < existing
    }

    private static func date(from timestamp: String) throws -> Date {
        guard let date = CostUsageScanner.dateFromTimestamp(timestamp) else {
            throw LedgerError.invalidTimestamp(timestamp)
        }
        return date
    }

    private static func add(
        _ totals: Totals,
        on date: Date,
        timeZone: TimeZone,
        to days: inout [String: Totals])
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        var dayTotals = days[key] ?? .zero
        dayTotals.add(totals)
        days[key] = dayTotals
    }

    private static func addRow(
        _ observation: AcceptedObservation,
        timeZone: TimeZone,
        to rows: inout [DailyRowKey: DailyRowValue])
    {
        let key = DailyRowKey(day: self.dayKey(for: observation.date, timeZone: timeZone), model: observation.model)
        var value = rows[key] ?? DailyRowValue()
        value.totals.add(observation.last)
        if let cost = CostUsagePricing.codexCostUSD(
            model: observation.model,
            inputTokens: observation.last.input,
            cachedInputTokens: observation.last.cached,
            outputTokens: observation.last.output)
        {
            value.costUSD += cost
        } else {
            value.isPriced = false
        }
        rows[key] = value
    }

    private static func dailyRows(from rows: [DailyRowKey: DailyRowValue]) -> [DailyRow] {
        rows.map { key, value in
            DailyRow(
                day: key.day,
                model: key.model,
                totals: value.totals,
                costUSD: value.isPriced ? value.costUSD : nil)
        }.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    private static func dayKey(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private struct DisjointSet {
        private var parents: [String: String] = [:]

        mutating func insert(_ item: String) {
            if self.parents[item] == nil {
                self.parents[item] = item
            }
        }

        mutating func find(_ item: String) -> String {
            self.insert(item)
            guard let parent = self.parents[item], parent != item else { return item }
            let root = self.find(parent)
            self.parents[item] = root
            return root
        }

        mutating func union(_ first: String, _ second: String) {
            let firstRoot = self.find(first)
            let secondRoot = self.find(second)
            if firstRoot != secondRoot {
                self.parents[secondRoot] = firstRoot
            }
        }
    }
}
