import Foundation

/// Classifies differences between local Codex accounting paths and a finalized UTC usage source.
///
/// This is an analysis seam, not an oracle-tuning mechanism. Callers supply independently observed
/// totals and corpus diagnostics; the classifier only applies a documented, bounded policy.
enum CodexLineageResidualClassifier {
    enum Classification: String, Equatable, Sendable {
        case invalidInput
        case provisional
        case withinTolerance
        case unavailableHistory
        case unsupportedEventShape
        case utcLocalAttribution
        case accountingSemantics
        case containment
        case ledgerDefect
    }

    struct Evidence: Equatable, Sendable {
        var localCorpusWasExhaustive = false
        var rejectedObservationCount = 0
        var unresolvedParentCount = 0
        var duplicateObservationCount = 0
    }

    struct Sample: Equatable, Sendable {
        let day: String
        let referenceTokens: Int
        let isReferenceFinalized: Bool
        let isOrdinaryDay: Bool
        let legacyTokens: Int
        let ledgerUTCTokens: Int
        let ledgerLocalTokens: Int
        let evidence: Evidence
    }

    struct DayResult: Equatable, Sendable {
        let day: String
        let classification: Classification
        let legacyAbsoluteError: Int?
        let ledgerAbsoluteError: Int?
    }

    struct Report: Equatable, Sendable {
        let days: [DayResult]
        let finalizedReferenceTokens: Int
        let finalizedLegacyTokens: Int
        let finalizedLedgerTokens: Int
        let legacyAbsoluteError: Int
        let ledgerAbsoluteError: Int
        let ordinaryDayRegressionCount: Int
        let invalidSampleCount: Int

        var improvesAggregateError: Bool {
            self.ledgerAbsoluteError < self.legacyAbsoluteError
        }
    }

    struct Policy: Equatable, Sendable {
        /// A residual no larger than this fraction of the reference is not assigned a speculative cause.
        let largeResidualFraction: Double
        /// Ordinary days may move by this fraction before the ledger is considered regressive.
        let ordinaryDayRegressionFraction: Double

        static let validation = Self(
            largeResidualFraction: 0.05,
            ordinaryDayRegressionFraction: 0.01)
    }

    static func classify(samples: [Sample], policy: Policy = .validation) -> Report {
        let ordered = samples.sorted { $0.day < $1.day }
        let days = ordered.map { sample -> DayResult in
            guard Self.isValid(sample: sample, policy: policy) else {
                return DayResult(
                    day: sample.day,
                    classification: .invalidInput,
                    legacyAbsoluteError: nil,
                    ledgerAbsoluteError: nil)
            }
            guard sample.isReferenceFinalized else {
                return DayResult(
                    day: sample.day,
                    classification: .provisional,
                    legacyAbsoluteError: nil,
                    ledgerAbsoluteError: nil)
            }
            let legacyError = Self.absoluteDifference(sample.legacyTokens, sample.referenceTokens)
            let ledgerError = Self.absoluteDifference(sample.ledgerUTCTokens, sample.referenceTokens)
            return DayResult(
                day: sample.day,
                classification: Self.classification(
                    sample: sample,
                    legacyError: legacyError,
                    ledgerError: ledgerError,
                    policy: policy),
                legacyAbsoluteError: legacyError,
                ledgerAbsoluteError: ledgerError)
        }

        let finalized = ordered.filter { $0.isReferenceFinalized && Self.isValid(sample: $0, policy: policy) }
        let referenceTokens = finalized.reduce(0) { Self.saturatingSum($0, $1.referenceTokens) }
        let legacyTokens = finalized.reduce(0) { Self.saturatingSum($0, $1.legacyTokens) }
        let ledgerTokens = finalized.reduce(0) { Self.saturatingSum($0, $1.ledgerUTCTokens) }
        let ordinaryDayRegressionCount = finalized.count { sample in
            guard sample.isOrdinaryDay else { return false }
            let allowed = Self.threshold(
                reference: sample.referenceTokens,
                fraction: policy.ordinaryDayRegressionFraction)
            return Self.absoluteDifference(sample.ledgerUTCTokens, sample.referenceTokens)
                > Self.saturatingSum(Self.absoluteDifference(sample.legacyTokens, sample.referenceTokens), allowed)
        }

        return Report(
            days: days,
            finalizedReferenceTokens: referenceTokens,
            finalizedLegacyTokens: legacyTokens,
            finalizedLedgerTokens: ledgerTokens,
            legacyAbsoluteError: Self.absoluteDifference(legacyTokens, referenceTokens),
            ledgerAbsoluteError: Self.absoluteDifference(ledgerTokens, referenceTokens),
            ordinaryDayRegressionCount: ordinaryDayRegressionCount,
            invalidSampleCount: days.count { $0.classification == .invalidInput })
    }

    private static func classification(
        sample: Sample,
        legacyError: Int,
        ledgerError: Int,
        policy: Policy) -> Classification
    {
        let largeResidual = Self.threshold(
            reference: sample.referenceTokens,
            fraction: policy.largeResidualFraction)
        guard ledgerError > largeResidual else { return .withinTolerance }
        if sample.evidence.rejectedObservationCount > 0 {
            return .unsupportedEventShape
        }

        let ordinaryAllowance = Self.threshold(
            reference: sample.referenceTokens,
            fraction: policy.ordinaryDayRegressionFraction)
        if sample.isOrdinaryDay, ledgerError > Self.saturatingSum(legacyError, ordinaryAllowance) {
            return .ledgerDefect
        }

        let localError = Self.absoluteDifference(sample.ledgerLocalTokens, sample.referenceTokens)
        if Self.saturatingSum(ledgerError, ordinaryAllowance) < localError {
            return .utcLocalAttribution
        }
        if sample.evidence.unresolvedParentCount > 0 {
            return .containment
        }
        if sample.evidence.localCorpusWasExhaustive, sample.ledgerUTCTokens < sample.referenceTokens {
            return .unavailableHistory
        }
        if sample.evidence.duplicateObservationCount > 0, ledgerError < legacyError {
            return .containment
        }
        return .accountingSemantics
    }

    private static func threshold(reference: Int, fraction: Double) -> Int {
        let value = (Double(reference) * fraction).rounded(.up)
        return value >= Double(Int.max) ? Int.max : Int(value)
    }

    private static func absoluteDifference(_ lhs: Int, _ rhs: Int) -> Int {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    private static func isValid(sample: Sample, policy: Policy) -> Bool {
        sample.referenceTokens >= 0 &&
            sample.legacyTokens >= 0 &&
            sample.ledgerUTCTokens >= 0 &&
            sample.ledgerLocalTokens >= 0 &&
            sample.evidence.rejectedObservationCount >= 0 &&
            sample.evidence.unresolvedParentCount >= 0 &&
            sample.evidence.duplicateObservationCount >= 0 &&
            policy.largeResidualFraction.isFinite &&
            policy.largeResidualFraction >= 0 &&
            policy.ordinaryDayRegressionFraction.isFinite &&
            policy.ordinaryDayRegressionFraction >= 0
    }

    private static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
