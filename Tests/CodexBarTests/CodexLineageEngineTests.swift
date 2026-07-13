import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageEngineTests {
    @Test
    func `family fingerprints and totals are deterministic under input permutation`() throws {
        let first = Self.document(owner: "first", observations: [
            Self.observation(timestamp: "2026-07-09T12:01:00Z", input: 20, total: 30),
            Self.observation(timestamp: "2026-07-09T12:00:00Z", input: 10, total: 10),
        ])
        let child = Self.document(owner: "child", parent: "first", observations: [
            Self.observation(timestamp: "2026-07-09T12:02:00Z", input: 5, total: 35),
        ])
        let other = Self.document(owner: "other", observations: [
            Self.observation(timestamp: "2026-07-09T13:00:00Z", input: 7, total: 7),
        ])

        let forwardFamilies = try CodexLineageEngine.prepareFamilies(documents: [first, child, other])
        let reverseFamilies = try CodexLineageEngine.prepareFamilies(documents: [other, child, first])
        let forward = try CodexLineageEngine.reconcile(families: forwardFamilies, localTimeZone: .gmt)
        let reverse = try CodexLineageEngine.reconcile(families: reverseFamilies, localTimeZone: .gmt)

        #expect(forward.families.map(\.familyFingerprint) == reverse.families.map(\.familyFingerprint))
        #expect(forward.report == reverse.report)
        #expect(forward.report.utcDays["2026-07-09"]?.input == 42)
    }

    @Test
    func `warm reconciliation reuses unchanged families and recomputes only a changed family`() throws {
        let first = Self.document(owner: "first", observations: [Self.observation(input: 10, total: 10)])
        let second = Self.document(owner: "second", observations: [Self.observation(input: 20, total: 20)])
        let initialFamilies = try CodexLineageEngine.prepareFamilies(documents: [first, second])
        let initial = try CodexLineageEngine.reconcile(families: initialFamilies, localTimeZone: .gmt)
        let warm = try CodexLineageEngine.reconcile(
            families: initialFamilies,
            previousCache: initial.candidateCache,
            localTimeZone: .gmt)

        let changed = Self.document(owner: "second", observations: [Self.observation(input: 25, total: 25)])
        let changedFamilies = try CodexLineageEngine.prepareFamilies(documents: [first, changed])
        let updated = try CodexLineageEngine.reconcile(
            families: changedFamilies,
            previousCache: initial.candidateCache,
            localTimeZone: .gmt)

        #expect(warm.diagnostics.reusedFamilyCount == 2)
        #expect(warm.diagnostics.recomputedFamilyCount == 0)
        #expect(updated.diagnostics.reusedFamilyCount == 1)
        #expect(updated.diagnostics.recomputedFamilyCount == 1)
        #expect(updated.report.utcDays["2026-07-09"]?.input == 35)
    }

    @Test
    func `cache entries with mismatched family identity are recomputed`() throws {
        let first = Self.document(owner: "first", observations: [Self.observation(input: 10, total: 10)])
        let second = Self.document(owner: "second", observations: [Self.observation(input: 20, total: 20)])
        let families = try CodexLineageEngine.prepareFamilies(documents: [first, second])
        let initial = try CodexLineageEngine.reconcile(families: families, localTimeZone: .gmt)
        let entries = initial.candidateCache.familiesByInputFingerprint.sorted { $0.key.value < $1.key.value }
        let mismatched = CodexLineageEngine.Cache(
            algorithmVersion: initial.candidateCache.algorithmVersion,
            familiesByInputFingerprint: [entries[0].key: entries[1].value, entries[1].key: entries[0].value])

        let rebuilt = try CodexLineageEngine.reconcile(
            families: families,
            previousCache: mismatched,
            localTimeZone: .gmt)

        #expect(rebuilt.diagnostics.reusedFamilyCount == 0)
        #expect(rebuilt.diagnostics.recomputedFamilyCount == 2)
        #expect(rebuilt.report.utcDays["2026-07-09"]?.input == 30)
    }

    @Test
    func `changing projection timezone recomputes families and does not reuse stale local days`() throws {
        let document = Self.document(owner: "first", observations: [
            Self.observation(timestamp: "2026-07-10T02:00:00Z", input: 10, total: 10),
        ])
        let families = try CodexLineageEngine.prepareFamilies(documents: [document])
        let utc = try CodexLineageEngine.reconcile(families: families, localTimeZone: .gmt)
        let newYork = try CodexLineageEngine.reconcile(
            families: families,
            previousCache: utc.candidateCache,
            localTimeZone: #require(TimeZone(identifier: "America/New_York")))

        #expect(newYork.diagnostics.reusedFamilyCount == 0)
        #expect(newYork.diagnostics.recomputedFamilyCount == 1)
        #expect(utc.report.localDays["2026-07-10"]?.input == 10)
        #expect(newYork.report.localDays["2026-07-09"]?.input == 10)
    }

    @Test
    func `new parent merges only affected families while unrelated family remains reusable`() throws {
        let child = Self.document(
            owner: "child",
            parent: "parent",
            observations: [Self.observation(input: 10, total: 10)])
        let parent = Self.document(owner: "parent", observations: [Self.observation(input: 20, total: 20)])
        let unrelated = Self.document(owner: "other", observations: [Self.observation(input: 5, total: 5)])
        let unresolved: Set<CodexLineageLedger.ParentIdentity> = [.init(sessionID: "parent")]
        let initialFamilies = try CodexLineageEngine.prepareFamilies(
            documents: [child, unrelated],
            unresolvedParents: unresolved)
        let initial = try CodexLineageEngine.reconcile(families: initialFamilies, localTimeZone: .gmt)

        let resolvedFamilies = try CodexLineageEngine.prepareFamilies(documents: [child, parent, unrelated])
        let resolved = try CodexLineageEngine.reconcile(
            families: resolvedFamilies,
            previousCache: initial.candidateCache,
            localTimeZone: .gmt)

        #expect(resolved.diagnostics.familyCount == 2)
        #expect(resolved.diagnostics.reusedFamilyCount == 1)
        #expect(resolved.diagnostics.recomputedFamilyCount == 1)
        #expect(resolved.report.utcDays["2026-07-09"]?.input == 35)
    }

    @Test
    func `cancelled publication leaves the prior cache unchanged`() throws {
        let family = try CodexLineageEngine.prepareFamilies(documents: [
            Self.document(owner: "first", observations: [Self.observation(input: 10, total: 10)]),
        ])
        let result = try CodexLineageEngine.reconcile(families: family, localTimeZone: .gmt)
        var published = CodexLineageEngine.Cache.empty

        #expect(throws: CancellationError.self) {
            try CodexLineageEngine.publish(
                result.candidateCache,
                to: &published,
                checkCancellation: { throw CancellationError() })
        }
        #expect(published == .empty)

        try CodexLineageEngine.publish(result.candidateCache, to: &published)
        #expect(published == result.candidateCache)
    }

    @Test
    func `structural diagnostics bound reconciliation scratch state to the largest family`() throws {
        let repeated = (0..<2000).map { index in
            Self.observation(
                timestamp: String(format: "2026-07-09T12:%02d:%02dZ", (index / 60) % 60, index % 60),
                input: 1,
                total: index + 1)
        }
        let documents = [
            Self.document(owner: "large", observations: repeated),
            Self.document(owner: "small", observations: Array(repeated.prefix(100))),
        ]
        let families = try CodexLineageEngine.prepareFamilies(documents: documents)
        let result = try CodexLineageEngine.reconcile(families: families, localTimeZone: .gmt)

        #expect(result.diagnostics.observationCount == 2100)
        #expect(result.diagnostics.peakFamilyObservationCount == 2000)
        #expect(result.diagnostics.peakAcceptedFingerprintCount <= 2000)
    }

    @Test(.timeLimit(.minutes(2)))
    func `duplicate heavy multi million observation family keeps one accepted fingerprint`() throws {
        let repeated = Array(repeating: Self.observation(input: 1, total: 1), count: 100_000)
        let documents = (0..<20).map { index in
            Self.document(
                owner: "owner-\(index)",
                parent: index == 0 ? nil : "owner-0",
                observations: repeated)
        }
        let families = try CodexLineageEngine.prepareFamilies(documents: documents)

        let result = try CodexLineageEngine.reconcile(families: families, localTimeZone: .gmt)

        #expect(result.diagnostics.observationCount == 2_000_000)
        #expect(result.diagnostics.peakFamilyObservationCount == 2_000_000)
        #expect(result.diagnostics.peakAcceptedFingerprintCount == 1)
        #expect(result.report.acceptedObservationCount == 1)
        #expect(result.report.duplicateObservationCount == 1_999_999)
    }

    @Test
    func `cancellation propagates during preparation and reconciliation without a candidate`() throws {
        let documents = (0..<20).map { index in
            Self.document(owner: "owner-\(index)", observations: [Self.observation(input: index + 1, total: index + 1)])
        }
        var preparationChecks = 0
        #expect(throws: CancellationError.self) {
            _ = try CodexLineageEngine.prepareFamilies(documents: documents) {
                preparationChecks += 1
                if preparationChecks == 5 {
                    throw CancellationError()
                }
            }
        }

        let families = try CodexLineageEngine.prepareFamilies(documents: documents)
        var reconciliationChecks = 0
        #expect(throws: CancellationError.self) {
            _ = try CodexLineageEngine.reconcile(families: families, localTimeZone: .gmt) {
                reconciliationChecks += 1
                if reconciliationChecks == 5 {
                    throw CancellationError()
                }
            }
        }
    }

    private static func document(
        owner: String,
        parent: String? = nil,
        observations: [CodexLineageLedger.Observation]) -> CodexLineageLedger.Document
    {
        .init(
            ownerID: owner,
            metadataSessionID: owner,
            parentSessionID: parent,
            observations: observations)
    }

    private static func observation(
        timestamp: String = "2026-07-09T12:00:00Z",
        input: Int,
        total: Int) -> CodexLineageLedger.Observation
    {
        .init(
            timestamp: timestamp,
            last: .init(input: input, cached: 0, output: 0),
            total: .init(input: total, cached: 0, output: 0))
    }
}
