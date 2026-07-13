import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageLedgerTests {
    @Test
    func `transitive lineage counts copied observations once`() throws {
        let first = Self.observation(timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100)
        let second = Self.observation(timestamp: "2026-07-09T12:01:00Z", input: 50, totalInput: 150)
        let third = Self.observation(timestamp: "2026-07-09T12:02:00Z", input: 25, totalInput: 175)
        let documents = [
            Self.document(owner: "root", observations: [first]),
            Self.document(owner: "child", metadata: "root", parent: "root", observations: [first, second]),
            Self.document(owner: "grandchild", metadata: "child", parent: "child", observations: [
                first,
                second,
                third,
            ]),
        ]

        let report = try CodexLineageLedger.reconcile(
            documents: documents,
            localTimeZone: #require(TimeZone(identifier: "America/New_York")))

        #expect(report.utcDays["2026-07-09"]?.input == 175)
        #expect(report.localDays["2026-07-09"]?.input == 175)
        #expect(report.componentCount == 1)
        #expect(report.acceptedObservationCount == 3)
        #expect(report.duplicateObservationCount == 3)
    }

    @Test
    func `equal observations in disconnected lineages remain additive`() throws {
        let observation = Self.observation(timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100)
        let report = try CodexLineageLedger.reconcile(
            documents: [
                Self.document(owner: "first", observations: [observation]),
                Self.document(owner: "second", observations: [observation]),
            ],
            localTimeZone: #require(TimeZone(identifier: "America/New_York")))

        #expect(report.utcDays["2026-07-09"]?.input == 200)
        #expect(report.componentCount == 2)
        #expect(report.acceptedObservationCount == 2)
        #expect(report.duplicateObservationCount == 0)
    }

    @Test
    func `unchanged state reemissions within a lineage count once`() throws {
        let observation = Self.observation(timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100)
        let report = try CodexLineageLedger.reconcile(
            documents: [Self.document(owner: "root", observations: [observation, observation, observation])],
            localTimeZone: #require(TimeZone(identifier: "America/New_York")))

        #expect(report.utcDays["2026-07-09"]?.input == 100)
        #expect(report.acceptedObservationCount == 1)
        #expect(report.duplicateObservationCount == 2)
    }

    @Test
    func `complete token state distinguishes observations within a lineage`() throws {
        let first = Self.observation(
            timestamp: "2026-07-09T12:00:00Z",
            input: 100,
            cached: 40,
            output: 10,
            totalInput: 100)
        let changedTotal = Self.observation(
            timestamp: "2026-07-09T12:01:00Z",
            input: 100,
            cached: 40,
            output: 10,
            totalInput: 200)
        let changedLast = Self.observation(
            timestamp: "2026-07-09T12:02:00Z",
            input: 125,
            cached: 50,
            output: 15,
            totalInput: 200)
        let report = try CodexLineageLedger.reconcile(
            documents: [
                Self.document(owner: "root", observations: [first, changedTotal, changedLast]),
            ],
            localTimeZone: #require(TimeZone(identifier: "America/New_York")))

        #expect(report.utcDays["2026-07-09"] == .init(input: 325, cached: 130, output: 35))
        #expect(report.acceptedObservationCount == 3)
        #expect(report.duplicateObservationCount == 0)
    }

    @Test
    func `UTC and local projections preserve their distinct day boundaries`() throws {
        let observation = Self.observation(timestamp: "2026-07-10T02:00:00Z", input: 100, totalInput: 100)
        let report = try CodexLineageLedger.reconcile(
            documents: [Self.document(owner: "root", observations: [observation])],
            localTimeZone: #require(TimeZone(identifier: "America/New_York")))

        #expect(report.utcDays["2026-07-10"]?.input == 100)
        #expect(report.localDays["2026-07-09"]?.input == 100)
    }

    @Test(arguments: [
        ("archived-fork-33ce-3869", 15_309_178),
        ("live-fork-4d90-52bf", 26_801_911),
    ])
    func `sanitized fork fixtures collapse copied prefixes and unchanged reemissions`(
        fixtureName: String,
        expectedTokens: Int) throws
    {
        let fixture = try SanitizedForkFamilyFixture.load(named: fixtureName)
        let parentMetadata = try fixture.sessionMetadata(named: "parent")
        let childMetadata = try fixture.sessionMetadata(named: "child")
        let parent = try fixture.events(named: "parent")
        let child = try fixture.events(named: "child")
        let documents = [
            CodexLineageLedger.Document(
                ownerID: "parent-owner",
                metadataSessionID: parentMetadata.id,
                parentSessionID: parentMetadata.forkedFromID,
                observations: parent.map(Self.observation)),
            CodexLineageLedger.Document(
                ownerID: "child-owner",
                metadataSessionID: childMetadata.id,
                parentSessionID: childMetadata.forkedFromID,
                observations: child.map(Self.observation)),
        ]

        let report = try CodexLineageLedger.reconcile(
            documents: documents,
            localTimeZone: #require(TimeZone(identifier: "America/New_York")))
        let total = report.utcDays.values.reduce(0) { partial, totals in
            partial + totals.input + totals.output
        }

        #expect(total == expectedTokens)
        #expect(total < fixture.manifest.oracle.dedupedLastTokens)
    }

    @Test
    func `document order does not change lineage totals or attribution`() throws {
        let copiedLater = Self.observation(timestamp: "2026-07-10T00:05:00Z", input: 100, totalInput: 100)
        let original = Self.observation(timestamp: "2026-07-09T23:55:00Z", input: 100, totalInput: 100)
        let root = Self.document(owner: "root", observations: [original])
        let child = Self.document(owner: "child", parent: "root", observations: [copiedLater])
        let timeZone = try #require(TimeZone(identifier: "America/New_York"))

        let forward = try CodexLineageLedger.reconcile(documents: [root, child], localTimeZone: timeZone)
        let reversed = try CodexLineageLedger.reconcile(documents: [child, root], localTimeZone: timeZone)

        #expect(forward == reversed)
        #expect(forward.utcDays["2026-07-09"]?.input == 100)
        #expect(forward.utcDays["2026-07-10"] == nil)
    }

    private static func document(
        owner: String,
        metadata: String? = nil,
        parent: String? = nil,
        observations: [CodexLineageLedger.Observation]) -> CodexLineageLedger.Document
    {
        .init(
            ownerID: owner,
            metadataSessionID: metadata,
            parentSessionID: parent,
            observations: observations)
    }

    private static func observation(
        timestamp: String,
        input: Int,
        cached: Int = 0,
        output: Int = 0,
        totalInput: Int) -> CodexLineageLedger.Observation
    {
        .init(
            timestamp: timestamp,
            last: .init(input: input, cached: cached, output: output),
            total: .init(input: totalInput, cached: cached, output: output))
    }

    private static func observation(
        _ event: SanitizedForkFamilyFixture.TokenEvent) -> CodexLineageLedger.Observation
    {
        .init(
            timestamp: event.timestamp,
            last: .init(
                input: event.last.inputTokens,
                cached: event.last.cachedInputTokens,
                output: event.last.outputTokens),
            total: .init(
                input: event.total.inputTokens,
                cached: event.total.cachedInputTokens,
                output: event.total.outputTokens))
    }
}
