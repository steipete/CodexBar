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
        let eventID: String?
        let timestamp: String
        let model: String
        let last: Totals
        let total: Totals

        init(
            eventID: String? = nil,
            timestamp: String,
            model: String = CostUsagePricing.codexUnattributedModel,
            last: Totals,
            total: Totals)
        {
            self.eventID = eventID
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
        let scopeID: String
        let incompleteObservationCount: Int

        init(
            ownerID: String,
            metadataSessionID: String?,
            parentSessionID: String?,
            observations: [Observation],
            scopeID: String = "",
            incompleteObservationCount: Int = 0)
        {
            self.ownerID = ownerID
            self.metadataSessionID = metadataSessionID
            self.parentSessionID = parentSessionID
            self.observations = observations
            self.scopeID = scopeID
            self.incompleteObservationCount = incompleteObservationCount
        }
    }

    enum ContainmentReason: String, CaseIterable, Equatable, Hashable, Sendable {
        case malformedTimestamp
        case incompleteObservation
        case conflictingOwnerIdentity
        case identityCollision
        case ancestryCycle
    }

    enum FamilyQuality: Equatable, Sendable {
        case primary
        case incompleteProvenance
        case contained(Set<ContainmentReason>)
    }

    struct FamilyDisposition: Equatable, Sendable {
        let scopeID: String
        let ownerIDs: Set<String>
        let quality: FamilyQuality
    }

    struct ParentIdentity: Equatable, Hashable, Sendable {
        let scopeID: String
        let sessionID: String

        init(scopeID: String = "", sessionID: String) {
            self.scopeID = scopeID
            self.sessionID = sessionID
        }
    }

    struct ConservativeReport: Equatable, Sendable {
        let primary: Report
        let families: [FamilyDisposition]
        let containedDocuments: [Document]
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
            let ownerID = Self.scoped(document.ownerID, document: document)
            graph.insert(ownerID)
            if let metadataSessionID = Self.nonEmpty(document.metadataSessionID) {
                graph.union(ownerID, Self.scoped(metadataSessionID, document: document))
            }
            if let parentSessionID = Self.nonEmpty(document.parentSessionID) {
                graph.union(ownerID, Self.scoped(parentSessionID, document: document))
            }
        }

        var documentsByComponent: [String: [Document]] = [:]
        for document in documents {
            let componentID = graph.find(Self.scoped(document.ownerID, document: document))
            documentsByComponent[componentID, default: []].append(document)
        }
        var physicalObservationCount = 0
        var utcDays: [String: Totals] = [:]
        var localDays: [String: Totals] = [:]
        var utcRows: [DailyRowKey: DailyRowValue] = [:]
        var localRows: [DailyRowKey: DailyRowValue] = [:]
        var acceptedObservationCount = 0
        for componentDocuments in documentsByComponent.values {
            try checkCancellation?()
            let parentByOwner = Self.physicalParents(componentDocuments)
            var accepted: [ObservationIdentity: AcceptedObservation] = [:]
            var acceptedByFingerprint: [Fingerprint: [String: ObservationIdentity]] = [:]
            for document in Self.parentsFirst(componentDocuments, parentByOwner: parentByOwner) {
                let ownerID = Self.scoped(document.ownerID, document: document)
                for observation in document.observations {
                    try checkCancellation?()
                    physicalObservationCount += 1
                    let date = try Self.date(from: observation.timestamp)
                    let fingerprint = Fingerprint(last: observation.last, total: observation.total)
                    let proposedIdentity = ObservationIdentity(
                        eventID: Self.nonEmpty(observation.eventID),
                        fingerprint: fingerprint)
                    let comparableIdentity = Self.comparableIdentity(
                        ownerID: ownerID,
                        acceptedByOwner: acceptedByFingerprint[fingerprint],
                        parentByOwner: parentByOwner)
                    let identity = accepted[proposedIdentity] == nil ? comparableIdentity ?? proposedIdentity :
                        proposedIdentity
                    if let existing = accepted[identity] {
                        if existing.date < date { continue }
                        if existing.date == date,
                           !Self.shouldPreferModel(observation.model, over: existing.model)
                        {
                            continue
                        }
                    }
                    accepted[identity] = AcceptedObservation(
                        date: date,
                        model: observation.model,
                        last: observation.last)
                    if identity == proposedIdentity {
                        acceptedByFingerprint[fingerprint, default: [:]][ownerID] = identity
                    }
                }
            }
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
            componentCount: Set(documents.map { graph.find(Self.scoped($0.ownerID, document: $0)) }).count,
            acceptedObservationCount: acceptedObservationCount,
            duplicateObservationCount: physicalObservationCount - acceptedObservationCount)
    }

    /// Routes every lineage family to either primary ledger accounting or explicit containment.
    /// Contained documents are returned to the caller for a future family-scoped fallback; they never
    /// contribute to `primary`, which prevents double accounting by construction.
    static func reconcileConservatively(
        documents: [Document],
        unresolvedParents: Set<ParentIdentity> = [],
        localTimeZone: TimeZone,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> ConservativeReport
    {
        var graph = DisjointSet()
        for document in documents {
            try checkCancellation?()
            let owner = Self.scoped(document.ownerID, document: document)
            graph.insert(owner)
            if let metadata = Self.nonEmpty(document.metadataSessionID) {
                graph.union(owner, Self.scoped(metadata, document: document))
            }
            if let parent = Self.nonEmpty(document.parentSessionID) {
                graph.union(owner, Self.scoped(parent, document: document))
            }
        }

        var documentsByFamily: [String: [Document]] = [:]
        for document in documents {
            try checkCancellation?()
            let family = graph.find(Self.scoped(document.ownerID, document: document))
            documentsByFamily[family, default: []].append(document)
        }

        var primaryDocuments: [Document] = []
        var containedDocuments: [Document] = []
        var families: [FamilyDisposition] = []
        for familyDocuments in documentsByFamily.values {
            try checkCancellation?()
            let reasons = Self.containmentReasons(in: familyDocuments)
            let owners = Set(familyDocuments.map(\.ownerID))
            let unresolved = familyDocuments.contains { document in
                guard let parent = Self.nonEmpty(document.parentSessionID) else { return false }
                return unresolvedParents.contains(.init(
                    scopeID: document.scopeID,
                    sessionID: Self.canonicalIdentity(parent)))
            }
            let quality: FamilyQuality
            if reasons.isEmpty {
                quality = unresolved ? .incompleteProvenance : .primary
                primaryDocuments.append(contentsOf: familyDocuments)
            } else {
                quality = .contained(reasons)
                containedDocuments.append(contentsOf: familyDocuments)
            }
            families.append(FamilyDisposition(
                scopeID: familyDocuments.first?.scopeID ?? "",
                ownerIDs: owners,
                quality: quality))
        }

        families.sort {
            ($0.scopeID, $0.ownerIDs.sorted().joined(separator: "\u{0}"))
                < ($1.scopeID, $1.ownerIDs.sorted().joined(separator: "\u{0}"))
        }
        containedDocuments.sort(by: Self.documentComesBefore)
        return try ConservativeReport(
            primary: Self.reconcile(
                documents: primaryDocuments,
                localTimeZone: localTimeZone,
                checkCancellation: checkCancellation),
            families: families,
            containedDocuments: containedDocuments)
    }

    private struct Fingerprint: Equatable, Hashable {
        let last: Totals
        let total: Totals
    }

    private enum ObservationIdentity: Equatable, Hashable {
        case event(String, Fingerprint)
        case fingerprint(Fingerprint)

        init(eventID: String?, fingerprint: Fingerprint) {
            self = eventID.map { .event($0, fingerprint) } ?? .fingerprint(fingerprint)
        }
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

    private static func scoped(_ identity: String, document: Document) -> String {
        document.scopeID + "\u{0}" + self.canonicalIdentity(identity)
    }

    private static func canonicalIdentity(_ identity: String) -> String {
        UUID(uuidString: identity)?.uuidString.lowercased() ?? identity
    }

    private static func physicalParents(_ documents: [Document]) -> [String: String] {
        let physicalOwners = Set(documents.map { Self.scoped($0.ownerID, document: $0) })
        var result: [String: String] = [:]
        for document in documents {
            guard let parent = Self.nonEmpty(document.parentSessionID) else { continue }
            let owner = Self.scoped(document.ownerID, document: document)
            let parentIdentity = Self.scoped(parent, document: document)
            guard physicalOwners.contains(parentIdentity), parentIdentity != owner else { continue }
            result[owner] = parentIdentity
        }
        return result
    }

    private static func comparableIdentity(
        ownerID: String,
        acceptedByOwner: [String: ObservationIdentity]?,
        parentByOwner: [String: String]) -> ObservationIdentity?
    {
        guard let acceptedByOwner else { return nil }
        var current: String? = ownerID
        var visited: Set<String> = []
        while let candidate = current, visited.insert(candidate).inserted {
            if let identity = acceptedByOwner[candidate] { return identity }
            current = parentByOwner[candidate]
        }
        return nil
    }

    private static func parentsFirst(_ documents: [Document], parentByOwner: [String: String]) -> [Document] {
        var depths: [String: Int] = [:]
        func depth(_ owner: String) -> Int {
            if let cached = depths[owner] { return cached }
            var path: [String] = []
            var current = owner
            var seen: Set<String> = []
            while let parent = parentByOwner[current], seen.insert(current).inserted {
                path.append(current)
                current = parent
            }
            let base = depths[current] ?? 0
            for (offset, item) in path.reversed().enumerated() {
                depths[item] = base + offset + 1
            }
            depths[owner] = depths[owner] ?? base
            return depths[owner] ?? 0
        }
        return documents.sorted { lhs, rhs in
            let lhsDepth = depth(Self.scoped(lhs.ownerID, document: lhs))
            let rhsDepth = depth(Self.scoped(rhs.ownerID, document: rhs))
            return lhsDepth == rhsDepth ? Self.documentComesBefore(lhs, rhs) : lhsDepth < rhsDepth
        }
    }

    private static func documentComesBefore(_ lhs: Document, _ rhs: Document) -> Bool {
        let lhsKey = [
            lhs.scopeID,
            lhs.ownerID,
            lhs.metadataSessionID ?? "",
            lhs.parentSessionID ?? "",
            String(lhs.incompleteObservationCount),
            lhs.observations.map(Self.observationSortKey).joined(separator: "\u{1}"),
        ].joined(separator: "\u{0}")
        let rhsKey = [
            rhs.scopeID,
            rhs.ownerID,
            rhs.metadataSessionID ?? "",
            rhs.parentSessionID ?? "",
            String(rhs.incompleteObservationCount),
            rhs.observations.map(Self.observationSortKey).joined(separator: "\u{1}"),
        ].joined(separator: "\u{0}")
        return lhsKey < rhsKey
    }

    private static func observationSortKey(_ observation: Observation) -> String {
        [
            observation.timestamp,
            observation.model,
            String(observation.last.input),
            String(observation.last.cached),
            String(observation.last.output),
            String(observation.total.input),
            String(observation.total.cached),
            String(observation.total.output),
        ].joined(separator: "\u{0}")
    }

    private static func containmentReasons(in documents: [Document]) -> Set<ContainmentReason> {
        var reasons: Set<ContainmentReason> = []
        if documents.contains(where: { $0.incompleteObservationCount > 0 }) {
            reasons.insert(.incompleteObservation)
        }
        if documents.flatMap(\.observations)
            .contains(where: { CostUsageScanner.dateFromTimestamp($0.timestamp) == nil })
        {
            reasons.insert(.malformedTimestamp)
        }
        let ownerGroups = Dictionary(grouping: documents, by: \.ownerID)
        if ownerGroups.values.contains(where: { group in
            let metadataIDs = Set(group.compactMap { Self.nonEmpty($0.metadataSessionID) })
            let parentIDs = Set(group.compactMap { Self.nonEmpty($0.parentSessionID) })
            return metadataIDs.count > 1 || parentIDs.count > 1
        }) {
            reasons.insert(.conflictingOwnerIdentity)
        }
        let metadataGroups = Dictionary(grouping: documents.compactMap { document in
            Self.nonEmpty(document.metadataSessionID).map { (Self.canonicalIdentity($0), document) }
        }, by: \.0)
        if metadataGroups.contains(where: { metadataID, entries in
            let documents = entries.map(\.1)
            let owners = Set(documents.map { Self.canonicalIdentity($0.ownerID) })
            guard owners.count > 1, !owners.contains(metadataID) else { return false }
            return !documents.allSatisfy {
                $0.parentSessionID.map(Self.canonicalIdentity) == metadataID
            }
        }) {
            reasons.insert(.identityCollision)
        }
        if Self.hasAncestryCycle(documents) {
            reasons.insert(.ancestryCycle)
        }
        return reasons
    }

    private static func hasAncestryCycle(_ documents: [Document]) -> Bool {
        let metadataOwners = Dictionary(grouping: documents.compactMap { document in
            document.metadataSessionID.map { ($0, document.ownerID) }
        }, by: \.0).mapValues { Set($0.map(\.1)) }
        var parents: [String: Set<String>] = [:]
        for document in documents {
            guard let parent = Self.nonEmpty(document.parentSessionID) else { continue }
            var targets = metadataOwners[parent] ?? [parent]
            if parent != document.ownerID {
                targets.remove(document.ownerID)
            }
            parents[document.ownerID, default: []].formUnion(targets)
        }
        var visiting: Set<String> = []
        var visited: Set<String> = []
        func visit(_ owner: String) -> Bool {
            if visiting.contains(owner) {
                return true
            }
            if visited.contains(owner) {
                return false
            }
            visiting.insert(owner)
            for parent in parents[owner] ?? [] where visit(parent) {
                return true
            }
            visiting.remove(owner)
            visited.insert(owner)
            return false
        }
        return Set(documents.map(\.ownerID)).contains(where: visit)
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
