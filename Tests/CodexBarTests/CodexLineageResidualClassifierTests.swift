import Testing
@testable import CodexBarCore

struct CodexLineageResidualClassifierTests {
    @Test
    func `sanitized finalized UTC replay materially closes the aggregate gap`() {
        let report = CodexLineageResidualClassifier.classify(samples: Self.forkHeavySamples)

        #expect(report.finalizedReferenceTokens == 3_692_873_480)
        #expect(report.finalizedLegacyTokens == 2_882_545_128)
        #expect(report.finalizedLedgerTokens == 3_589_444_942)
        #expect(report.legacyAbsoluteError == 810_328_352)
        #expect(report.ledgerAbsoluteError == 103_428_538)
        #expect(report.improvesAggregateError)
        #expect(report.days.allSatisfy { day in
            guard let legacy = day.legacyAbsoluteError, let ledger = day.ledgerAbsoluteError else { return true }
            return ledger < legacy
        })
    }

    @Test
    func `large undercount is unavailable history only after exhaustive local checks`() {
        let verified = CodexLineageResidualClassifier.classify(samples: [Self.forkHeavySamples[0]])
        #expect(verified.days.first?.classification == .unavailableHistory)

        var incomplete = Self.forkHeavySamples[0]
        incomplete = .init(
            day: incomplete.day,
            referenceTokens: incomplete.referenceTokens,
            isReferenceFinalized: true,
            isOrdinaryDay: false,
            legacyTokens: incomplete.legacyTokens,
            ledgerUTCTokens: incomplete.ledgerUTCTokens,
            ledgerLocalTokens: incomplete.ledgerLocalTokens,
            evidence: .init(localCorpusWasExhaustive: false))
        let unverified = CodexLineageResidualClassifier.classify(samples: [incomplete])
        #expect(unverified.days.first?.classification == .accountingSemantics)
    }

    @Test
    func `ordinary non-fork days do not materially regress`() {
        let samples = [
            Self.ordinary(day: "2026-06-29", legacy: 120_000_000, ledger: 120_000_000),
            Self.ordinary(day: "2026-06-30", legacy: 180_000_000, ledger: 180_000_000),
            Self.ordinary(day: "2026-07-05", legacy: 290_018_710, ledger: 290_777_623),
            Self.ordinary(day: "2026-07-06", legacy: 435_123_419, ledger: 435_123_419),
            Self.ordinary(day: "2026-07-07", legacy: 324_480_000, ledger: 324_480_000),
            Self.ordinary(day: "2026-07-08", legacy: 240_000_000, ledger: 240_000_000),
        ]

        let report = CodexLineageResidualClassifier.classify(samples: samples)
        #expect(report.ordinaryDayRegressionCount == 0)
        #expect(report.days.allSatisfy { $0.classification == .withinTolerance })
    }

    @Test
    func `reference day remains provisional until finalized`() {
        let sample = CodexLineageResidualClassifier.Sample(
            day: "2026-07-12",
            referenceTokens: 618_121_840,
            isReferenceFinalized: false,
            isOrdinaryDay: false,
            legacyTokens: 600_000_000,
            ledgerUTCTokens: 615_000_000,
            ledgerLocalTokens: 610_000_000,
            evidence: .init())

        let report = CodexLineageResidualClassifier.classify(samples: [sample])
        #expect(report.days.first?.classification == .provisional)
        #expect(report.finalizedReferenceTokens == 0)
        #expect(report.days.first?.ledgerAbsoluteError == nil)
    }

    @Test
    func `invalid token evidence is excluded without overflowing aggregate totals`() {
        let invalid = CodexLineageResidualClassifier.Sample(
            day: "2026-07-08",
            referenceTokens: -1,
            isReferenceFinalized: true,
            isOrdinaryDay: true,
            legacyTokens: 10,
            ledgerUTCTokens: 10,
            ledgerLocalTokens: 10,
            evidence: .init())
        let large = CodexLineageResidualClassifier.Sample(
            day: "2026-07-09",
            referenceTokens: Int.max,
            isReferenceFinalized: true,
            isOrdinaryDay: false,
            legacyTokens: Int.max,
            ledgerUTCTokens: Int.max,
            ledgerLocalTokens: Int.max,
            evidence: .init())

        let report = CodexLineageResidualClassifier.classify(samples: [invalid, large, large])

        #expect(report.days.first?.classification == .invalidInput)
        #expect(report.invalidSampleCount == 1)
        #expect(report.finalizedReferenceTokens == Int.max)
        #expect(report.finalizedLegacyTokens == Int.max)
        #expect(report.finalizedLedgerTokens == Int.max)
        #expect(report.legacyAbsoluteError == 0)
        #expect(report.ledgerAbsoluteError == 0)
    }

    private static let forkHeavySamples = [
        CodexLineageResidualClassifier.Sample(
            day: "2026-07-09",
            referenceTokens: 852_682_935,
            isReferenceFinalized: true,
            isOrdinaryDay: false,
            legacyTokens: 946_818_053,
            ledgerUTCTokens: 764_026_920,
            ledgerLocalTokens: 764_026_920,
            evidence: .init(localCorpusWasExhaustive: true, duplicateObservationCount: 100)),
        CodexLineageResidualClassifier.Sample(
            day: "2026-07-10",
            referenceTokens: 1_580_199_588,
            isReferenceFinalized: true,
            isOrdinaryDay: false,
            legacyTokens: 1_414_122_342,
            ledgerUTCTokens: 1_510_013_760,
            ledgerLocalTokens: 1_430_000_000,
            evidence: .init(localCorpusWasExhaustive: true, duplicateObservationCount: 100)),
        CodexLineageResidualClassifier.Sample(
            day: "2026-07-11",
            referenceTokens: 1_259_990_957,
            isReferenceFinalized: true,
            isOrdinaryDay: false,
            legacyTokens: 521_604_733,
            ledgerUTCTokens: 1_315_404_262,
            ledgerLocalTokens: 1_200_000_000,
            evidence: .init(localCorpusWasExhaustive: true, duplicateObservationCount: 100)),
    ]

    private static func ordinary(day: String, legacy: Int, ledger: Int) -> CodexLineageResidualClassifier.Sample {
        .init(
            day: day,
            referenceTokens: legacy,
            isReferenceFinalized: true,
            isOrdinaryDay: true,
            legacyTokens: legacy,
            ledgerUTCTokens: ledger,
            ledgerLocalTokens: ledger,
            evidence: .init(localCorpusWasExhaustive: true))
    }
}
