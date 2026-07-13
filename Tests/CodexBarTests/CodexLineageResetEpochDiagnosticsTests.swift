import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageResetEpochDiagnosticsTests {
    @Test
    func `monotonic reemission is not reset evidence`() throws {
        let repeated = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 100)
        let report = try Self.analyze([repeated, repeated])

        #expect(report == .empty)
    }

    @Test
    func `same owner fingerprint repeated after strong reset is estimated once`() throws {
        let report = try Self.analyze([
            Self.observation("2026-07-09T12:00:00Z", last: 10, total: 100),
            Self.observation("2026-07-09T12:01:00Z", last: 1, total: 1),
            Self.observation("2026-07-10T00:01:00Z", last: 10, total: 100),
            Self.observation("2026-07-10T00:02:00Z", last: 10, total: 100),
        ])

        #expect(report.strongResetBoundaryCount == 1)
        #expect(report.postResetRepeatedFingerprintCount == 1)
        #expect(report.sameOwnerRepeatCount == 1)
        #expect(report.crossOwnerRepeatCount == 0)
        #expect(report.estimatedSuppressed == .init(input: 10, cached: 0, output: 0))
        #expect(report.estimatedSuppressedUTC == [
            "2026-07-10": .init(input: 10, cached: 0, output: 0),
        ])
        #expect(report.sameOwnerEstimatedSuppressed == .init(input: 10, cached: 0, output: 0))
        #expect(report.sameOwnerEstimatedSuppressedUTC == [
            "2026-07-10": .init(input: 10, cached: 0, output: 0),
        ])
    }

    @Test
    func `mixed regression does not open a reset epoch`() throws {
        let first = CodexLineageLedger.Observation(
            timestamp: "2026-07-09T12:00:00Z",
            last: .init(input: 10, cached: 0, output: 1),
            total: .init(input: 100, cached: 0, output: 10))
        let mixed = CodexLineageLedger.Observation(
            timestamp: "2026-07-09T12:01:00Z",
            last: .init(input: 10, cached: 0, output: 1),
            total: .init(input: 90, cached: 0, output: 11))
        let report = try Self.analyze([first, mixed])

        #expect(report.strongResetBoundaryCount == 0)
        #expect(report.mixedRegressionCount == 1)
        #expect(report.postResetRepeatedFingerprintCount == 0)
    }

    @Test
    func `copied child without local reset is not reset evidence`() throws {
        let observation = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 100)
        let parent = Self.document(owner: "parent", observations: [observation])
        let child = CodexLineageLedger.Document(
            ownerID: "child",
            metadataSessionID: "child",
            parentSessionID: "parent",
            observations: [observation])
        let family = try #require(try CodexLineageEngine.prepareFamilies(documents: [parent, child]).first)

        let report = try CodexLineageResetEpochDiagnostics.analyze(families: [family])

        #expect(report == .empty)
    }

    @Test
    func `duplicate documents with the same owner do not manufacture reset history`() throws {
        let repeated = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 100)
        let reset = Self.observation("2026-07-09T12:01:00Z", last: 1, total: 1)
        let replay = Self.observation("2026-07-09T12:02:00Z", last: 10, total: 100)
        let firstCopy = Self.document(owner: "owner", observations: [repeated])
        let beforeReset = Self.observation("2026-07-09T11:59:00Z", last: 20, total: 200)
        let secondCopy = Self.document(owner: "owner", observations: [beforeReset, reset, replay])
        let family = try #require(try CodexLineageEngine.prepareFamilies(
            documents: [firstCopy, secondCopy]).first)

        let report = try CodexLineageResetEpochDiagnostics.analyze(families: [family])

        #expect(report.strongResetBoundaryCount == 1)
        #expect(report.postResetRepeatedFingerprintCount == 0)
    }

    @Test
    func `cross owner evidence requires a distinct earlier owner`() throws {
        let fingerprint = Self.observation("2026-07-09T12:00:00Z", last: 10, total: 100)
        let parent = Self.document(owner: "parent", observations: [fingerprint])
        let child = CodexLineageLedger.Document(
            ownerID: "child",
            metadataSessionID: "child",
            parentSessionID: "parent",
            observations: [
                Self.observation("2026-07-09T12:01:00Z", last: 20, total: 200),
                Self.observation("2026-07-09T12:02:00Z", last: 1, total: 1),
                Self.observation("2026-07-09T12:03:00Z", last: 10, total: 100),
            ])
        let family = try #require(try CodexLineageEngine.prepareFamilies(documents: [parent, child]).first)

        let report = try CodexLineageResetEpochDiagnostics.analyze(families: [family])

        #expect(report.sameOwnerRepeatCount == 0)
        #expect(report.crossOwnerRepeatCount == 1)
    }

    private static func analyze(
        _ observations: [CodexLineageLedger.Observation]) throws -> CodexLineageResetEpochDiagnostics.Report
    {
        let family = try #require(try CodexLineageEngine.prepareFamilies(
            documents: [Self.document(owner: "owner", observations: observations)]).first)
        return try CodexLineageResetEpochDiagnostics.analyze(families: [family])
    }

    private static func document(
        owner: String,
        observations: [CodexLineageLedger.Observation]) -> CodexLineageLedger.Document
    {
        .init(ownerID: owner, metadataSessionID: owner, parentSessionID: nil, observations: observations)
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
