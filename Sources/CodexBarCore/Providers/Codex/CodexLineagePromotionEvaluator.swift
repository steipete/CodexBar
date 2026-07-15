import Foundation

/// Evidence-based gate for promoting lineage accounting behind a reversible authority switch.
///
/// This evaluator does not choose token totals or tune an error percentage. It verifies that the
/// independently collected correctness and operational evidence is complete enough to promote.
enum CodexLineagePromotionEvaluator {
    /// Opaque proof that the full promotion contract passed. Only `evaluate` can create one.
    struct Authorization: Equatable, Sendable {
        fileprivate init() {}
    }

    enum CancellationStage: String, CaseIterable, Equatable, Hashable, Sendable {
        case rootIndexing
        case parsing
        case graphConstruction
        case reconciliation
        case prePublication
    }

    struct FamilyRoutingEvidence: Equatable, Sendable {
        let primaryFamilyCount: Int
        let containedFamilyCount: Int
        let doubleContributionFamilyCount: Int
        let permanentContainmentSupported: Bool
    }

    struct PerformanceEvidence: Equatable, Sendable {
        let coldMeasured: Bool
        let warmMeasured: Bool
        let memoryBoundMeasured: Bool
        /// Set only after review finds a correctness-neutral regression material enough to block promotion.
        let hasMaterialRegression: Bool
    }

    struct RollbackEvidence: Equatable, Sendable {
        let legacyWholeScanAvailable: Bool
        let rollbackPathVerified: Bool
    }

    struct Input: Equatable, Sendable {
        let residualReport: CodexLineageResidualClassifier.Report
        /// Finalized fork-heavy UTC days whose ledger error must be lower than legacy error.
        let targetDays: Set<String>
        /// Large residuals require an explicit human-reviewed classification before promotion.
        let reviewedResidualDays: Set<String>
        let adversarialGoldensPassed: Bool
        let boundedDiscoveryPassed: Bool
        let familyRouting: FamilyRoutingEvidence
        let performance: PerformanceEvidence
        let cancellationStages: Set<CancellationStage>
        let atomicPublicationPassed: Bool
        let rollback: RollbackEvidence
    }

    enum Blocker: String, CaseIterable, Equatable, Hashable, Sendable {
        case invalidResidualEvidence
        case missingTargetDay
        case provisionalTargetDay
        case targetDayNotImproved
        case aggregateErrorNotImproved
        case ordinaryDayRegression
        case unreviewedLargeResidual
        case ledgerDefect
        case adversarialGoldenFailure
        case boundedDiscoveryFailure
        case containmentUnavailable
        case familyDoubleContribution
        case performanceEvidenceMissing
        case materialPerformanceRegression
        case cancellationEvidenceMissing
        case atomicPublicationFailure
        case legacyRollbackUnavailable
        case rollbackUnverified
    }

    struct Decision: Equatable, Sendable {
        /// Canonical case order keeps logs, snapshots, and review artifacts deterministic.
        let blockers: [Blocker]

        var canPromote: Bool {
            self.blockers.isEmpty
        }

        /// Promotion never removes the permanent family-level containment route.
        let keepsFamilyContainment: Bool
        /// Legacy remains a whole-scan emergency authority until its dedicated removal work.
        let keepsLegacyEmergencyRollback: Bool

        let authorization: Authorization?

        fileprivate init(
            blockers: [Blocker],
            keepsFamilyContainment: Bool,
            keepsLegacyEmergencyRollback: Bool,
            authorization: Authorization?)
        {
            self.blockers = blockers
            self.keepsFamilyContainment = keepsFamilyContainment
            self.keepsLegacyEmergencyRollback = keepsLegacyEmergencyRollback
            self.authorization = authorization
        }
    }

    static func evaluate(_ input: Input) -> Decision {
        var blockers: Set<Blocker> = []
        let report = input.residualReport
        Self.addReportBlockers(report, to: &blockers)
        var daysByID: [String: CodexLineageResidualClassifier.DayResult] = [:]
        for day in report.days {
            if daysByID.updateValue(day, forKey: day.day) != nil {
                blockers.insert(.invalidResidualEvidence)
            }
            if day.classification == .ledgerDefect {
                blockers.insert(.ledgerDefect)
            }
            if Self.requiresReview(day.classification), !input.reviewedResidualDays.contains(day.day) {
                blockers.insert(.unreviewedLargeResidual)
            }
        }
        Self.addTargetBlockers(input.targetDays, daysByID: daysByID, to: &blockers)
        Self.addOperationalBlockers(input, to: &blockers)

        let orderedBlockers = Blocker.allCases.filter(blockers.contains)
        return Decision(
            blockers: orderedBlockers,
            keepsFamilyContainment: input.familyRouting.permanentContainmentSupported,
            keepsLegacyEmergencyRollback: input.rollback.legacyWholeScanAvailable,
            authorization: orderedBlockers.isEmpty ? Authorization() : nil)
    }

    private static func addReportBlockers(
        _ report: CodexLineageResidualClassifier.Report,
        to blockers: inout Set<Blocker>)
    {
        if !self.hasValidShape(report) || report.invalidSampleCount > 0 {
            blockers.insert(.invalidResidualEvidence)
        }
        if !report.improvesAggregateError {
            blockers.insert(.aggregateErrorNotImproved)
        }
        if report.ordinaryDayRegressionCount > 0 {
            blockers.insert(.ordinaryDayRegression)
        }
    }

    private static func addTargetBlockers(
        _ targetDays: Set<String>,
        daysByID: [String: CodexLineageResidualClassifier.DayResult],
        to blockers: inout Set<Blocker>)
    {
        if targetDays.isEmpty {
            blockers.insert(.missingTargetDay)
        }
        for targetDay in targetDays {
            guard let day = daysByID[targetDay] else {
                blockers.insert(.missingTargetDay)
                continue
            }
            if day.classification == .provisional {
                blockers.insert(.provisionalTargetDay)
            } else if day.classification == .invalidInput {
                blockers.insert(.invalidResidualEvidence)
            } else if let legacyError = day.legacyAbsoluteError, let ledgerError = day.ledgerAbsoluteError,
                      ledgerError >= legacyError
            {
                blockers.insert(.targetDayNotImproved)
            }
        }
    }

    private static func addOperationalBlockers(_ input: Input, to blockers: inout Set<Blocker>) {
        if !input.adversarialGoldensPassed {
            blockers.insert(.adversarialGoldenFailure)
        }
        if !input.boundedDiscoveryPassed {
            blockers.insert(.boundedDiscoveryFailure)
        }
        if !input.familyRouting.permanentContainmentSupported {
            blockers.insert(.containmentUnavailable)
        }
        if input.familyRouting.doubleContributionFamilyCount != 0 {
            blockers.insert(.familyDoubleContribution)
        }
        let familyCountIsInvalid = input.familyRouting.primaryFamilyCount < 0
            || input.familyRouting.containedFamilyCount < 0
            || input.familyRouting.doubleContributionFamilyCount < 0
            || (input.familyRouting.primaryFamilyCount == 0 && input.familyRouting.containedFamilyCount == 0)
        if familyCountIsInvalid {
            blockers.insert(.invalidResidualEvidence)
        }
        if !input.performance.coldMeasured || !input.performance.warmMeasured || !input.performance
            .memoryBoundMeasured
        {
            blockers.insert(.performanceEvidenceMissing)
        }
        if input.performance.hasMaterialRegression {
            blockers.insert(.materialPerformanceRegression)
        }
        if input.cancellationStages != Set(CancellationStage.allCases) {
            blockers.insert(.cancellationEvidenceMissing)
        }
        if !input.atomicPublicationPassed {
            blockers.insert(.atomicPublicationFailure)
        }
        if !input.rollback.legacyWholeScanAvailable {
            blockers.insert(.legacyRollbackUnavailable)
        }
        if !input.rollback.rollbackPathVerified {
            blockers.insert(.rollbackUnverified)
        }
    }

    private static func hasValidShape(_ report: CodexLineageResidualClassifier.Report) -> Bool {
        guard report.invalidSampleCount >= 0,
              report.ordinaryDayRegressionCount >= 0,
              report.finalizedReferenceTokens >= 0,
              report.finalizedLegacyTokens >= 0,
              report.finalizedLedgerTokens >= 0,
              report.legacyAbsoluteError >= 0,
              report.ledgerAbsoluteError >= 0,
              report.invalidSampleCount == report.days.count(where: { $0.classification == .invalidInput }),
              report.legacyAbsoluteError == abs(report.finalizedLegacyTokens - report.finalizedReferenceTokens),
              report.ledgerAbsoluteError == abs(report.finalizedLedgerTokens - report.finalizedReferenceTokens)
        else { return false }
        return report.days.allSatisfy { day in
            switch day.classification {
            case .invalidInput, .provisional:
                day.legacyAbsoluteError == nil && day.ledgerAbsoluteError == nil
            case .withinTolerance, .unavailableHistory, .unsupportedEventShape, .utcLocalAttribution,
                 .accountingSemantics, .containment, .ledgerDefect:
                day.legacyAbsoluteError != nil && day.ledgerAbsoluteError != nil
            }
        }
    }

    private static func requiresReview(_ classification: CodexLineageResidualClassifier.Classification) -> Bool {
        switch classification {
        case .withinTolerance:
            false
        case .invalidInput, .provisional:
            false
        case .unavailableHistory, .unsupportedEventShape, .utcLocalAttribution, .accountingSemantics,
             .containment, .ledgerDefect:
            true
        }
    }
}
