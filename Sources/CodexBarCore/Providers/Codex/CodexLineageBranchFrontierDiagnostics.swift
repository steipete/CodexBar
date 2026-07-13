import Foundation

/// Counterfactual evidence for numeric token snapshots that recur after fork branches diverge.
/// This type cannot produce accounting rows or selector input and therefore cannot change totals.
enum CodexLineageBranchFrontierDiagnostics {
    struct Report: Equatable, Sendable {
        var familyCount: Int
        var eligibleFamilyCount: Int
        var ownerCount: Int
        var eligibleOwnerCount: Int
        var ambiguousOwnerHistoryCount: Int
        var resolvedParentEdgeCount: Int
        var unresolvedParentEdgeCount: Int
        var sharedPrefixFingerprintCount: Int
        var sharedPrefixDuplicateOccurrenceCount: Int
        var strongPostFrontierFingerprintCount: Int
        var strongPostFrontierDuplicateOccurrenceCount: Int
        var ambiguousPostFrontierFingerprintCount: Int
        var ambiguousPostFrontierBranchInstanceCount: Int
        var unknownPostFrontierFingerprintCount: Int
        var estimatedSuppressed: CodexLineageLedger.Totals
        var estimatedSuppressedUTC: [String: CodexLineageLedger.Totals]
        var peakFamilyObservationCount: Int
        var peakFingerprintOccurrenceCount: Int
        var skippedOversizeFamilyCount: Int
        var overflowedEstimateCount: Int

        static let empty = Self(
            familyCount: 0,
            eligibleFamilyCount: 0,
            ownerCount: 0,
            eligibleOwnerCount: 0,
            ambiguousOwnerHistoryCount: 0,
            resolvedParentEdgeCount: 0,
            unresolvedParentEdgeCount: 0,
            sharedPrefixFingerprintCount: 0,
            sharedPrefixDuplicateOccurrenceCount: 0,
            strongPostFrontierFingerprintCount: 0,
            strongPostFrontierDuplicateOccurrenceCount: 0,
            ambiguousPostFrontierFingerprintCount: 0,
            ambiguousPostFrontierBranchInstanceCount: 0,
            unknownPostFrontierFingerprintCount: 0,
            estimatedSuppressed: .zero,
            estimatedSuppressedUTC: [:],
            peakFamilyObservationCount: 0,
            peakFingerprintOccurrenceCount: 0,
            skippedOversizeFamilyCount: 0,
            overflowedEstimateCount: 0)
    }

    private static let maximumFamilyObservationCount = 1_000_000

    private struct Fingerprint: Hashable { let last: CodexLineageLedger.Totals; let total: CodexLineageLedger.Totals }
    private struct CopyKey: Hashable { let date: Date; let fingerprint: Fingerprint }
    private struct OwnerHistory {
        let owner: String
        let parent: String?
        let keys: [CopyKey]
        var frontier: Int?
    }

    private struct PostOccurrence {
        let owner: String
        let key: CopyKey
        let previous: CopyKey?
        let next: CopyKey?
        let hasDivergenceWitness: Bool
    }

    private struct OccurrenceIdentity: Hashable { let owner: String; let key: CopyKey }

    private struct StrongContext: Hashable { let current: CopyKey; let previous: CopyKey; let next: CopyKey }

    // The diagnostic intentionally keeps its family-local state machine linear and auditable.
    // swiftlint:disable:next cyclomatic_complexity
    static func analyze(
        families: [CodexLineageEngine.PreparedFamily],
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Report
    {
        var report = Report.empty
        for family in families {
            try checkCancellation?()
            report.familyCount += 1
            report.peakFamilyObservationCount = max(report.peakFamilyObservationCount, family.observationCount)
            if family.observationCount > Self.maximumFamilyObservationCount {
                report.skippedOversizeFamilyCount += 1
                continue
            }
            let grouped = Dictionary(grouping: family.documents, by: Self.ownerKey)
            report.ownerCount += grouped.count
            var histories: [String: OwnerHistory] = [:]
            for (owner, documents) in grouped {
                try checkCancellation?()
                guard let keys = try Self.canonicalHistory(documents, checkCancellation: checkCancellation) else {
                    report.ambiguousOwnerHistoryCount += 1
                    continue
                }
                let parents = Set(documents.compactMap { Self.nonEmpty($0.parentSessionID) }
                    .map(Self.canonicalIdentity))
                guard parents.count <= 1 else {
                    report.ambiguousOwnerHistoryCount += 1
                    continue
                }
                histories[owner] = OwnerHistory(owner: owner, parent: parents.first, keys: keys, frontier: nil)
            }
            report.eligibleOwnerCount += histories.count
            guard !histories.isEmpty else { continue }

            let ownerByIdentity = Dictionary(uniqueKeysWithValues: histories.keys.map { (Self.unscoped($0), $0) })
            let aliases = Dictionary(grouping: family.documents.compactMap { document -> (String, String)? in
                guard let metadata = Self.nonEmpty(document.metadataSessionID) else { return nil }
                return (Self.canonicalIdentity(metadata), Self.ownerKey(document))
            }, by: \.0).mapValues { Set($0.map(\.1)) }
            for owner in histories.keys.sorted() {
                try checkCancellation?()
                guard let parentID = histories[owner]?.parent else { continue }
                let parent = ownerByIdentity[parentID] ?? aliases[parentID]?.onlyElement
                guard let parent, let childKeys = histories[owner]?.keys,
                      let parentKeys = histories[parent]?.keys
                else {
                    report.unresolvedParentEdgeCount += 1
                    continue
                }
                report.resolvedParentEdgeCount += 1
                let prefix = try Self.commonPrefix(
                    childKeys,
                    parentKeys,
                    checkCancellation: checkCancellation)
                guard prefix > 0 else { continue }
                histories[owner]?.frontier = prefix
                report.sharedPrefixFingerprintCount += Set(childKeys.prefix(prefix).map(\.fingerprint)).count
                report.sharedPrefixDuplicateOccurrenceCount += prefix
            }

            var postByFingerprint: [Fingerprint: [PostOccurrence]] = [:]
            for history in histories.values {
                guard let frontier = history.frontier, frontier < history.keys.count else { continue }
                for index in frontier..<history.keys.count {
                    try checkCancellation?()
                    let occurrence = PostOccurrence(
                        owner: history.owner,
                        key: history.keys[index],
                        previous: index > 0 ? history.keys[index - 1] : nil,
                        next: index + 1 < history.keys.count ? history.keys[index + 1] : nil,
                        hasDivergenceWitness: index > frontier)
                    postByFingerprint[occurrence.key.fingerprint, default: []].append(occurrence)
                }
            }
            for (fingerprint, occurrences) in postByFingerprint where Set(occurrences.map(\.owner)).count > 1 {
                try checkCancellation?()
                report.peakFingerprintOccurrenceCount = max(report.peakFingerprintOccurrenceCount, occurrences.count)
                let strongGroups = Dictionary(
                    grouping: occurrences.compactMap { occurrence -> (StrongContext, OccurrenceIdentity)? in
                        guard let previous = occurrence.previous, let next = occurrence.next else { return nil }
                        return (
                            StrongContext(current: occurrence.key, previous: previous, next: next),
                            OccurrenceIdentity(owner: occurrence.owner, key: occurrence.key))
                    },
                    by: \.0).values.map { Set($0.map(\.1)) }
                    .filter { Set($0.map(\.owner)).count > 1 }
                let strongOccurrences = strongGroups.reduce(into: Set<OccurrenceIdentity>()) { $0.formUnion($1) }
                if !strongGroups.isEmpty {
                    report.strongPostFrontierFingerprintCount += 1
                    report.strongPostFrontierDuplicateOccurrenceCount += strongGroups.reduce(0) {
                        $0 + Set($1.map(\.owner)).count - 1
                    }
                }
                let nonStrong = occurrences.filter {
                    !strongOccurrences.contains(.init(owner: $0.owner, key: $0.key))
                }
                let hasDistinctOccurrenceTimes = Set(nonStrong.map(\.key.date)).count > 1
                let independentOwners = hasDistinctOccurrenceTimes ?
                    Set(nonStrong.filter(\.hasDivergenceWitness).map(\.owner)) : []
                if independentOwners.count > 1 {
                    report.ambiguousPostFrontierFingerprintCount += 1
                    report.ambiguousPostFrontierBranchInstanceCount += independentOwners.count
                    let suppressedCopies = independentOwners.count - 1
                    guard let suppressed = Self.multiplied(fingerprint.last, by: suppressedCopies),
                          let aggregate = Self.adding(report.estimatedSuppressed, suppressed)
                    else {
                        report.overflowedEstimateCount += 1
                        continue
                    }
                    report.estimatedSuppressed = aggregate
                    if let date = occurrences.filter({ independentOwners.contains($0.owner) }).map(\.key.date).min() {
                        let day = Self.utcDay(date)
                        let totals = report.estimatedSuppressedUTC[day] ?? .zero
                        if let updated = Self.adding(totals, suppressed) {
                            report.estimatedSuppressedUTC[day] = updated
                        } else {
                            report.overflowedEstimateCount += 1
                        }
                    }
                } else if strongGroups.isEmpty {
                    report.unknownPostFrontierFingerprintCount += 1
                }
            }
            report.eligibleFamilyCount += 1
        }
        return report
    }

    private static func canonicalHistory(
        _ documents: [CodexLineageLedger.Document],
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> [CopyKey]?
    {
        var histories: [[CopyKey]?] = []
        histories.reserveCapacity(documents.count)
        for document in documents {
            try checkCancellation?()
            var dated: [(Int, CopyKey)] = []
            for (index, observation) in document.observations.enumerated() {
                try checkCancellation?()
                guard document.incompleteObservationCount == 0,
                      let date = CostUsageScanner.dateFromTimestamp(observation.timestamp)
                else {
                    histories.append(nil)
                    break
                }
                dated.append((
                    index,
                    CopyKey(date: date, fingerprint: .init(last: observation.last, total: observation.total))))
            }
            guard dated.count == document.observations.count else { continue }
            dated.sort { $0.1.date != $1.1.date ? $0.1.date < $1.1.date : $0.0 < $1.0 }
            var seen: Set<CopyKey> = []
            histories.append(dated.compactMap { seen.insert($0.1).inserted ? $0.1 : nil })
        }
        guard !histories.contains(where: { $0 == nil }) else { return nil }
        let values = histories.compactMap(\.self).sorted { $0.count > $1.count }
        guard let longest = values.first,
              values.dropFirst().allSatisfy({ Array(longest.prefix($0.count)) == $0 }) else { return nil }
        return longest
    }

    private static func commonPrefix(
        _ lhs: [CopyKey],
        _ rhs: [CopyKey],
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> Int
    {
        var count = 0
        while count < min(lhs.count, rhs.count), lhs[count] == rhs[count] {
            try checkCancellation?()
            count += 1
        }
        return count
    }

    private static func ownerKey(_ document: CodexLineageLedger.Document) -> String {
        document.scopeID + "\u{0}" + self.canonicalIdentity(document.ownerID)
    }

    private static func unscoped(_ value: String) -> String {
        String(value.split(separator: "\u{0}").last ?? "")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func canonicalIdentity(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    private static func multiplied(
        _ totals: CodexLineageLedger.Totals,
        by count: Int) -> CodexLineageLedger.Totals?
    {
        let input = totals.input.multipliedReportingOverflow(by: count)
        let cached = totals.cached.multipliedReportingOverflow(by: count)
        let output = totals.output.multipliedReportingOverflow(by: count)
        guard !input.overflow, !cached.overflow, !output.overflow else { return nil }
        return .init(input: input.partialValue, cached: cached.partialValue, output: output.partialValue)
    }

    private static func adding(
        _ lhs: CodexLineageLedger.Totals,
        _ rhs: CodexLineageLedger.Totals) -> CodexLineageLedger.Totals?
    {
        let input = lhs.input.addingReportingOverflow(rhs.input)
        let cached = lhs.cached.addingReportingOverflow(rhs.cached)
        let output = lhs.output.addingReportingOverflow(rhs.output)
        guard !input.overflow, !cached.overflow, !output.overflow else { return nil }
        return .init(input: input.partialValue, cached: cached.partialValue, output: output.partialValue)
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension Set {
    fileprivate var onlyElement: Element? {
        self.count == 1 ? self.first : nil
    }
}
