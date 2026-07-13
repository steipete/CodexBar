import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageBranchFrontierDiagnosticsTests {
    @Test
    func `copied prefix and independently convergent suffix are distinguished`() throws {
        let prefix = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 10)
        let collisionA = Self.observation("2026-07-09T12:03:00Z", last: 30, total: 100)
        let collisionB = Self.observation("2026-07-09T12:04:00Z", last: 30, total: 100)
        let family = try Self.family([
            Self.document("root", observations: [prefix]),
            Self.document("first", parent: "root", observations: [
                prefix, Self.observation("2026-07-09T12:01:00Z", last: 20, total: 30), collisionA,
            ]),
            Self.document("second", parent: "root", observations: [
                prefix, Self.observation("2026-07-09T12:02:00Z", last: 25, total: 35), collisionB,
            ]),
        ])

        let report = try CodexLineageBranchFrontierDiagnostics.analyze(families: [family])

        #expect(report.sharedPrefixFingerprintCount == 2)
        #expect(report.sharedPrefixDuplicateOccurrenceCount == 2)
        #expect(report.ambiguousPostFrontierFingerprintCount == 1)
        #expect(report.ambiguousPostFrontierBranchInstanceCount == 2)
        #expect(report.estimatedSuppressed == .init(input: 30, cached: 0, output: 0))
        #expect(report.estimatedSuppressedUTC == ["2026-07-09": .init(input: 30, cached: 0, output: 0)])
    }

    @Test
    func `matching timestamp and neighboring flow is strong copy evidence`() throws {
        let prefix = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 10)
        let divergent = Self.observation("2026-07-09T12:01:00Z", last: 20, total: 30)
        let collision = Self.observation("2026-07-09T12:02:00Z", last: 30, total: 60)
        let following = Self.observation("2026-07-09T12:03:00Z", last: 40, total: 100)
        let family = try Self.family([
            Self.document("root", observations: [prefix]),
            Self.document("first", parent: "root", observations: [prefix, divergent, collision, following]),
            Self.document("second", parent: "root", observations: [prefix, divergent, collision, following]),
        ])

        let report = try CodexLineageBranchFrontierDiagnostics.analyze(families: [family])

        #expect(report.strongPostFrontierFingerprintCount == 2)
        #expect(report.strongPostFrontierDuplicateOccurrenceCount == 2)
        #expect(report.ambiguousPostFrontierFingerprintCount == 0)
        #expect(report.estimatedSuppressed == .zero)
    }

    @Test
    func `collision without two divergence witnesses remains unknown`() throws {
        let prefix = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 10)
        let collision = Self.observation("2026-07-09T12:02:00Z", last: 30, total: 60)
        let family = try Self.family([
            Self.document("root", observations: [prefix]),
            Self.document("first", parent: "root", observations: [prefix, collision]),
            Self.document("second", parent: "root", observations: [prefix, collision]),
        ])

        let report = try CodexLineageBranchFrontierDiagnostics.analyze(families: [family])

        #expect(report.unknownPostFrontierFingerprintCount == 1)
        #expect(report.estimatedSuppressed == .zero)
    }

    @Test
    func `strong copy does not hide a separate convergence from the same owner`() throws {
        let prefix = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 10)
        let copied = Self.observation("2026-07-09T12:02:00Z", last: 30, total: 60)
        let family = try Self.family([
            Self.document("root", observations: [prefix]),
            Self.document("first", parent: "root", observations: [
                prefix,
                Self.observation("2026-07-09T12:01:00Z", last: 20, total: 30),
                copied,
                Self.observation("2026-07-09T12:03:00Z", last: 40, total: 100),
                Self.observation("2026-07-09T12:06:00Z", last: 30, total: 60),
            ]),
            Self.document("second", parent: "root", observations: [
                prefix,
                Self.observation("2026-07-09T12:01:00Z", last: 20, total: 30),
                copied,
                Self.observation("2026-07-09T12:03:00Z", last: 40, total: 100),
            ]),
            Self.document("third", parent: "root", observations: [
                prefix,
                Self.observation("2026-07-09T12:04:00Z", last: 25, total: 35),
                Self.observation("2026-07-09T12:05:00Z", last: 30, total: 60),
            ]),
        ])

        let report = try CodexLineageBranchFrontierDiagnostics.analyze(families: [family])

        #expect(report.strongPostFrontierFingerprintCount == 2)
        #expect(report.strongPostFrontierDuplicateOccurrenceCount == 2)
        #expect(report.ambiguousPostFrontierFingerprintCount == 1)
        #expect(report.ambiguousPostFrontierBranchInstanceCount == 2)
        #expect(report.estimatedSuppressed == .init(input: 30, cached: 0, output: 0))
    }

    @Test
    func `diagnostics leave ledger accounting unchanged and are permutation stable`() throws {
        let prefix = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 10)
        let documents = [
            Self.document("root", observations: [prefix]),
            Self.document("first", parent: "root", observations: [
                prefix, Self.observation("2026-07-09T12:01:00Z", last: 20, total: 30),
                Self.observation("2026-07-09T12:03:00Z", last: 30, total: 100),
            ]),
            Self.document("second", parent: "root", observations: [
                prefix, Self.observation("2026-07-09T12:02:00Z", last: 25, total: 35),
                Self.observation("2026-07-09T12:04:00Z", last: 30, total: 100),
            ]),
        ]
        let before = try CodexLineageLedger.reconcile(documents: documents, localTimeZone: .gmt)
        let first = try CodexLineageBranchFrontierDiagnostics.analyze(families: [Self.family(documents)])
        let second = try CodexLineageBranchFrontierDiagnostics.analyze(families: [Self.family(documents.reversed())])
        let after = try CodexLineageLedger.reconcile(documents: documents, localTimeZone: .gmt)

        #expect(first == second)
        #expect(before == after)
    }

    private static func family(_ documents: some Sequence<CodexLineageLedger.Document>) throws -> CodexLineageEngine
        .PreparedFamily
    {
        try #require(try CodexLineageEngine.prepareFamilies(documents: Array(documents)).first)
    }

    private static func document(
        _ owner: String,
        parent: String? = nil,
        observations: [CodexLineageLedger.Observation]) -> CodexLineageLedger.Document
    {
        .init(ownerID: owner, metadataSessionID: owner, parentSessionID: parent, observations: observations)
    }

    private static func observation(
        _ timestamp: String,
        last: Int,
        total: Int) -> CodexLineageLedger.Observation
    {
        .init(
            timestamp: timestamp,
            last: .init(input: last, cached: 0, output: 0),
            total: .init(input: total, cached: 0, output: 0))
    }
}
