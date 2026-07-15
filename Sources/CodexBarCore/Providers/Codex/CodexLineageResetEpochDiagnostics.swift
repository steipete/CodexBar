import Foundation

/// Counterfactual shadow evidence for snapshots that recur after a strong cumulative-token reset.
/// This analyzer cannot produce accounting rows or selector input and never changes ledger totals.
enum CodexLineageResetEpochDiagnostics {
    struct Report: Equatable, Sendable {
        let strongResetBoundaryCount: Int
        let mixedRegressionCount: Int
        let postResetRepeatedFingerprintCount: Int
        let sameOwnerRepeatCount: Int
        let crossOwnerRepeatCount: Int
        let estimatedSuppressed: CodexLineageLedger.Totals
        let estimatedSuppressedUTC: [String: CodexLineageLedger.Totals]
        let sameOwnerEstimatedSuppressed: CodexLineageLedger.Totals
        let sameOwnerEstimatedSuppressedUTC: [String: CodexLineageLedger.Totals]

        static let empty = Self(
            strongResetBoundaryCount: 0,
            mixedRegressionCount: 0,
            postResetRepeatedFingerprintCount: 0,
            sameOwnerRepeatCount: 0,
            crossOwnerRepeatCount: 0,
            estimatedSuppressed: .zero,
            estimatedSuppressedUTC: [:],
            sameOwnerEstimatedSuppressed: .zero,
            sameOwnerEstimatedSuppressedUTC: [:])
    }

    private struct Fingerprint: Hashable {
        let last: CodexLineageLedger.Totals
        let total: CodexLineageLedger.Totals
    }

    private struct CandidateKey: Hashable {
        let owner: String
        let epoch: Int
        let fingerprint: Fingerprint
    }

    private struct Occurrence {
        let owner: String
        let stream: Int
        let epoch: Int
        let fingerprint: Fingerprint
        let date: Date
        let originalIndex: Int
    }

    static func analyze(
        families: [CodexLineageEngine.PreparedFamily],
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Report
    {
        var report = Report.empty
        for family in families {
            try checkCancellation?()
            var occurrences: [Occurrence] = []
            for (stream, document) in family.documents.enumerated() {
                try checkCancellation?()
                let owner = Self.ownerKey(document)
                var dated: [(Int, Date, CodexLineageLedger.Observation)] = []
                dated.reserveCapacity(document.observations.count)
                for (index, observation) in document.observations.enumerated() {
                    try checkCancellation?()
                    guard let date = CostUsageScanner.dateFromTimestamp(observation.timestamp) else { continue }
                    dated.append((index, date, observation))
                }
                dated.sort {
                    if $0.1 != $1.1 {
                        return $0.1 < $1.1
                    }
                    return $0.0 < $1.0
                }
                var epoch = 0
                var previous: CodexLineageLedger.Totals?
                var seenInEpoch: Set<Fingerprint> = []
                for (index, date, observation) in dated {
                    try checkCancellation?()
                    if let previous {
                        if Self.isStrongReset(from: previous, to: observation.total) {
                            epoch += 1
                            seenInEpoch.removeAll(keepingCapacity: true)
                            report = report.addingStrongReset()
                        } else if Self.isMixedRegression(from: previous, to: observation.total) {
                            report = report.addingMixedRegression()
                        }
                    }
                    previous = observation.total
                    let fingerprint = Fingerprint(last: observation.last, total: observation.total)
                    guard seenInEpoch.insert(fingerprint).inserted else { continue }
                    occurrences.append(.init(
                        owner: owner,
                        stream: stream,
                        epoch: epoch,
                        fingerprint: fingerprint,
                        date: date,
                        originalIndex: index))
                }
            }
            occurrences.sort {
                if $0.date != $1.date {
                    return $0.date < $1.date
                }
                if $0.owner != $1.owner {
                    return $0.owner < $1.owner
                }
                if $0.epoch != $1.epoch {
                    return $0.epoch < $1.epoch
                }
                return $0.originalIndex < $1.originalIndex
            }
            var familySeen: [Fingerprint: [String: Date]] = [:]
            var streamEpochs: [Int: [Fingerprint: Set<Int>]] = [:]
            var counted: Set<CandidateKey> = []
            for occurrence in occurrences {
                try checkCancellation?()
                let priorOwnerEpochs = streamEpochs[occurrence.stream]?[occurrence.fingerprint] ?? []
                let sameOwner = priorOwnerEpochs.contains { $0 < occurrence.epoch }
                let crossOwner = familySeen[occurrence.fingerprint]?.contains { owner, date in
                    owner != occurrence.owner && date < occurrence.date
                } ?? false
                let key = CandidateKey(
                    owner: occurrence.owner,
                    epoch: occurrence.epoch,
                    fingerprint: occurrence.fingerprint)
                if occurrence.epoch > 0, sameOwner || crossOwner, counted.insert(key).inserted {
                    report = report.addingCandidate(
                        occurrence.fingerprint.last,
                        day: Self.utcDayKey(from: occurrence.date),
                        sameOwner: sameOwner)
                }
                familySeen[occurrence.fingerprint, default: [:]][occurrence.owner] = min(
                    familySeen[occurrence.fingerprint]?[occurrence.owner] ?? occurrence.date,
                    occurrence.date)
                streamEpochs[occurrence.stream, default: [:]][occurrence.fingerprint, default: []]
                    .insert(occurrence.epoch)
            }
        }
        return report
    }

    private static func ownerKey(_ document: CodexLineageLedger.Document) -> String {
        let owner = UUID(uuidString: document.ownerID)?.uuidString.lowercased() ?? document.ownerID
        return document.scopeID + "\u{0}" + owner
    }

    private static func utcDayKey(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func isStrongReset(
        from previous: CodexLineageLedger.Totals,
        to current: CodexLineageLedger.Totals) -> Bool
    {
        let nonIncreasing = current.input <= previous.input && current.cached <= previous.cached
            && current.output <= previous.output
        return nonIncreasing && current != previous
    }

    private static func isMixedRegression(
        from previous: CodexLineageLedger.Totals,
        to current: CodexLineageLedger.Totals) -> Bool
    {
        let regressed = current.input < previous.input || current.cached < previous.cached
            || current.output < previous.output
        let increased = current.input > previous.input || current.cached > previous.cached
            || current.output > previous.output
        return regressed && increased
    }
}

extension CodexLineageResetEpochDiagnostics.Report {
    fileprivate func addingStrongReset() -> Self {
        .init(
            strongResetBoundaryCount: self.strongResetBoundaryCount + 1,
            mixedRegressionCount: self.mixedRegressionCount,
            postResetRepeatedFingerprintCount: self.postResetRepeatedFingerprintCount,
            sameOwnerRepeatCount: self.sameOwnerRepeatCount,
            crossOwnerRepeatCount: self.crossOwnerRepeatCount,
            estimatedSuppressed: self.estimatedSuppressed,
            estimatedSuppressedUTC: self.estimatedSuppressedUTC,
            sameOwnerEstimatedSuppressed: self.sameOwnerEstimatedSuppressed,
            sameOwnerEstimatedSuppressedUTC: self.sameOwnerEstimatedSuppressedUTC)
    }

    fileprivate func addingMixedRegression() -> Self {
        .init(
            strongResetBoundaryCount: self.strongResetBoundaryCount,
            mixedRegressionCount: self.mixedRegressionCount + 1,
            postResetRepeatedFingerprintCount: self.postResetRepeatedFingerprintCount,
            sameOwnerRepeatCount: self.sameOwnerRepeatCount,
            crossOwnerRepeatCount: self.crossOwnerRepeatCount,
            estimatedSuppressed: self.estimatedSuppressed,
            estimatedSuppressedUTC: self.estimatedSuppressedUTC,
            sameOwnerEstimatedSuppressed: self.sameOwnerEstimatedSuppressed,
            sameOwnerEstimatedSuppressedUTC: self.sameOwnerEstimatedSuppressedUTC)
    }

    fileprivate func addingCandidate(_ totals: CodexLineageLedger.Totals, day: String, sameOwner: Bool) -> Self {
        var estimated = self.estimatedSuppressed
        estimated.add(totals)
        var days = self.estimatedSuppressedUTC
        var dayTotals = days[day] ?? .zero
        dayTotals.add(totals)
        days[day] = dayTotals
        var sameOwnerEstimated = self.sameOwnerEstimatedSuppressed
        var sameOwnerDays = self.sameOwnerEstimatedSuppressedUTC
        if sameOwner {
            sameOwnerEstimated.add(totals)
            var sameOwnerDay = sameOwnerDays[day] ?? .zero
            sameOwnerDay.add(totals)
            sameOwnerDays[day] = sameOwnerDay
        }
        return .init(
            strongResetBoundaryCount: self.strongResetBoundaryCount,
            mixedRegressionCount: self.mixedRegressionCount,
            postResetRepeatedFingerprintCount: self.postResetRepeatedFingerprintCount + 1,
            sameOwnerRepeatCount: self.sameOwnerRepeatCount + (sameOwner ? 1 : 0),
            crossOwnerRepeatCount: self.crossOwnerRepeatCount + (sameOwner ? 0 : 1),
            estimatedSuppressed: estimated,
            estimatedSuppressedUTC: days,
            sameOwnerEstimatedSuppressed: sameOwnerEstimated,
            sameOwnerEstimatedSuppressedUTC: sameOwnerDays)
    }
}
