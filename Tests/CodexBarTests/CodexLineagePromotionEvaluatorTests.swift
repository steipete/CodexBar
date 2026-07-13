import Testing
@testable import CodexBarCore

struct CodexLineagePromotionEvaluatorTests {
    @Test
    func `complete evidence promotes while retaining containment and legacy rollback`() {
        let decision = CodexLineagePromotionEvaluator.evaluate(Self.readyInput())

        #expect(decision.canPromote)
        #expect(decision.blockers.isEmpty)
        #expect(decision.keepsFamilyContainment)
        #expect(decision.keepsLegacyEmergencyRollback)
    }

    @Test
    func `promotion is evidence based rather than a fixed aggregate percentage`() {
        let report = CodexLineageResidualClassifier.classify(samples: [
            Self.sample(
                day: "2026-07-09",
                reference: 1_000_000,
                legacy: 100_000,
                ledger: 100_001,
                ordinary: false,
                exhaustive: true),
        ])
        var input = Self.readyInput(report: report, targetDays: ["2026-07-09"])
        input = .init(
            residualReport: input.residualReport,
            targetDays: input.targetDays,
            reviewedResidualDays: ["2026-07-09"],
            adversarialGoldensPassed: input.adversarialGoldensPassed,
            boundedDiscoveryPassed: input.boundedDiscoveryPassed,
            familyRouting: input.familyRouting,
            performance: input.performance,
            cancellationStages: input.cancellationStages,
            atomicPublicationPassed: input.atomicPublicationPassed,
            rollback: input.rollback)

        let decision = CodexLineagePromotionEvaluator.evaluate(input)
        #expect(decision.canPromote)
    }

    @Test
    func `ordinary regression and unreviewed residual block promotion`() {
        let report = CodexLineageResidualClassifier.classify(samples: [
            Self.sample(day: "2026-07-09", reference: 1000, legacy: 500, ledger: 900, ordinary: false),
            Self.sample(day: "2026-07-10", reference: 1000, legacy: 1000, ledger: 1100, ordinary: true),
        ])
        let ready = Self.readyInput(report: report, targetDays: ["2026-07-09"])
        let input = CodexLineagePromotionEvaluator.Input(
            residualReport: ready.residualReport,
            targetDays: ready.targetDays,
            reviewedResidualDays: [],
            adversarialGoldensPassed: ready.adversarialGoldensPassed,
            boundedDiscoveryPassed: ready.boundedDiscoveryPassed,
            familyRouting: ready.familyRouting,
            performance: ready.performance,
            cancellationStages: ready.cancellationStages,
            atomicPublicationPassed: ready.atomicPublicationPassed,
            rollback: ready.rollback)

        let decision = CodexLineagePromotionEvaluator.evaluate(input)
        #expect(decision.blockers.contains(.ordinaryDayRegression))
        #expect(decision.blockers.contains(.unreviewedLargeResidual))
        #expect(!decision.canPromote)
    }

    @Test
    func `non target large residual still requires review`() {
        let report = CodexLineageResidualClassifier.classify(samples: [
            Self.sample(day: "2026-07-09", reference: 1000, legacy: 500, ledger: 950, ordinary: false),
            Self.sample(day: "2026-07-10", reference: 1000, legacy: 100, ledger: 900, ordinary: false),
        ])
        let ready = Self.readyInput(report: report, targetDays: ["2026-07-09"])
        let input = CodexLineagePromotionEvaluator.Input(
            residualReport: ready.residualReport,
            targetDays: ready.targetDays,
            reviewedResidualDays: ["2026-07-09"],
            adversarialGoldensPassed: ready.adversarialGoldensPassed,
            boundedDiscoveryPassed: ready.boundedDiscoveryPassed,
            familyRouting: ready.familyRouting,
            performance: ready.performance,
            cancellationStages: ready.cancellationStages,
            atomicPublicationPassed: ready.atomicPublicationPassed,
            rollback: ready.rollback)

        #expect(CodexLineagePromotionEvaluator.evaluate(input).blockers == [.unreviewedLargeResidual])
    }

    @Test
    func `duplicate residual days fail closed without trapping`() {
        let sample = Self.sample(day: "2026-07-09", reference: 1000, legacy: 500, ledger: 950, ordinary: false)
        let report = CodexLineageResidualClassifier.classify(samples: [sample, sample])
        let decision = CodexLineagePromotionEvaluator.evaluate(Self.readyInput(
            report: report,
            targetDays: ["2026-07-09"]))

        #expect(decision.blockers.contains(.invalidResidualEvidence))
        #expect(!decision.canPromote)
    }

    @Test
    func `family overlap blocks promotion even when residual totals improve`() {
        let ready = Self.readyInput()
        let input = CodexLineagePromotionEvaluator.Input(
            residualReport: ready.residualReport,
            targetDays: ready.targetDays,
            reviewedResidualDays: ready.reviewedResidualDays,
            adversarialGoldensPassed: true,
            boundedDiscoveryPassed: true,
            familyRouting: .init(
                primaryFamilyCount: 10,
                containedFamilyCount: 2,
                doubleContributionFamilyCount: 1,
                permanentContainmentSupported: true),
            performance: ready.performance,
            cancellationStages: ready.cancellationStages,
            atomicPublicationPassed: true,
            rollback: ready.rollback)

        let decision = CodexLineagePromotionEvaluator.evaluate(input)
        #expect(decision.blockers == [.familyDoubleContribution])
    }

    @Test
    func `operational and rollback evidence are mandatory`() {
        let ready = Self.readyInput()
        let input = CodexLineagePromotionEvaluator.Input(
            residualReport: ready.residualReport,
            targetDays: ready.targetDays,
            reviewedResidualDays: ready.reviewedResidualDays,
            adversarialGoldensPassed: true,
            boundedDiscoveryPassed: true,
            familyRouting: ready.familyRouting,
            performance: .init(
                coldMeasured: true,
                warmMeasured: false,
                memoryBoundMeasured: false,
                hasMaterialRegression: true),
            cancellationStages: [.parsing, .reconciliation],
            atomicPublicationPassed: false,
            rollback: .init(legacyWholeScanAvailable: false, rollbackPathVerified: false))

        let decision = CodexLineagePromotionEvaluator.evaluate(input)
        #expect(decision.blockers.contains(.performanceEvidenceMissing))
        #expect(decision.blockers.contains(.materialPerformanceRegression))
        #expect(decision.blockers.contains(.cancellationEvidenceMissing))
        #expect(decision.blockers.contains(.atomicPublicationFailure))
        #expect(decision.blockers.contains(.legacyRollbackUnavailable))
        #expect(decision.blockers.contains(.rollbackUnverified))
        #expect(decision.blockers == CodexLineagePromotionEvaluator.Blocker.allCases.filter {
            decision.blockers.contains($0)
        })
    }

    private static func readyInput(
        report: CodexLineageResidualClassifier.Report? = nil,
        targetDays: Set<String> = ["2026-07-09", "2026-07-10"]) -> CodexLineagePromotionEvaluator.Input
    {
        let report = report ?? CodexLineageResidualClassifier.classify(samples: [
            Self.sample(day: "2026-07-09", reference: 1000, legacy: 500, ledger: 950, ordinary: false),
            Self.sample(day: "2026-07-10", reference: 2000, legacy: 1000, ledger: 1980, ordinary: false),
            Self.sample(day: "2026-07-08", reference: 500, legacy: 500, ledger: 500, ordinary: true),
        ])
        return .init(
            residualReport: report,
            targetDays: targetDays,
            reviewedResidualDays: targetDays,
            adversarialGoldensPassed: true,
            boundedDiscoveryPassed: true,
            familyRouting: .init(
                primaryFamilyCount: 10,
                containedFamilyCount: 2,
                doubleContributionFamilyCount: 0,
                permanentContainmentSupported: true),
            performance: .init(
                coldMeasured: true,
                warmMeasured: true,
                memoryBoundMeasured: true,
                hasMaterialRegression: false),
            cancellationStages: Set(CodexLineagePromotionEvaluator.CancellationStage.allCases),
            atomicPublicationPassed: true,
            rollback: .init(legacyWholeScanAvailable: true, rollbackPathVerified: true))
    }

    private static func sample(
        day: String,
        reference: Int,
        legacy: Int,
        ledger: Int,
        ordinary: Bool,
        exhaustive: Bool = false) -> CodexLineageResidualClassifier.Sample
    {
        .init(
            day: day,
            referenceTokens: reference,
            isReferenceFinalized: true,
            isOrdinaryDay: ordinary,
            legacyTokens: legacy,
            ledgerUTCTokens: ledger,
            ledgerLocalTokens: ledger,
            evidence: .init(localCorpusWasExhaustive: exhaustive, duplicateObservationCount: ordinary ? 0 : 1))
    }
}
