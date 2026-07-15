import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageLedgerTests {
    @Test
    func `fast rollout parser adapts complete token states into a ledger document`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let ownerID = "019f55a1-7f6e-70c0-8e4f-f5bbefa9b7ac"
        let fileURL = environment.root.appendingPathComponent(
            "rollout-2026-07-09T12-00-00-\(ownerID).jsonl")
        let contents = [
            #"{"type":"session_meta","payload":{"id":"metadata-id","forked_from_id":"parent-id"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}"#,
            Self.tokenCountLine(
                timestamp: "2026-07-09T12:00:00Z",
                last: (input: 100, cached: 40, output: 10),
                total: (input: 100, cached: 40, output: 10)),
            Self.tokenCountLine(
                timestamp: "2026-07-09T12:01:00Z",
                last: (input: 50, cached: 20, output: 5),
                total: (input: 150, cached: 60, output: 15)),
            #"{"type":"event_msg","timestamp":"2026-07-09T12:02:00Z","payload":{"type":"token_count","info":{"#
                + #""total_token_usage":{"input_tokens":200,"cached_input_tokens":80,"output_tokens":20}}}}"#,
        ].joined(separator: "\n")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        let document = try CostUsageScanner.parseCodexLineageDocument(fileURL: fileURL)

        #expect(document.ownerID == ownerID)
        #expect(document.metadataSessionID == "metadata-id")
        #expect(document.parentSessionID == "parent-id")
        #expect(document.observations.count == 2)
        #expect(document.observations.map(\.eventID) == ["turn-a:0", "turn-a:1"])
        #expect(document.observations[0].last == .init(input: 100, cached: 40, output: 10))
        #expect(document.observations[1].total == .init(input: 150, cached: 60, output: 15))
    }

    @Test
    func `snapshot only parsing skips lineage observation collection`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let fileURL = environment.root.appendingPathComponent("rollout-with-token-states.jsonl")
        let contents = [
            Self.tokenCountLine(
                timestamp: "2026-07-09T12:00:00Z",
                last: (input: 100, cached: 40, output: 10),
                total: (input: 100, cached: 40, output: 10)),
            Self.tokenCountLine(
                timestamp: "2026-07-09T12:01:00Z",
                last: (input: 50, cached: 20, output: 5),
                total: (input: 150, cached: 60, output: 15)),
        ].joined(separator: "\n")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshotsOnly = try CostUsageScanner.parseCodexTokenEvidenceCountsForTesting(
            fileURL: fileURL,
            collectLineageObservations: false)
        let lineage = try CostUsageScanner.parseCodexTokenEvidenceCountsForTesting(
            fileURL: fileURL,
            collectLineageObservations: true)

        #expect(snapshotsOnly.snapshots == 2)
        #expect(snapshotsOnly.observations == 0)
        #expect(lineage.snapshots == 2)
        #expect(lineage.observations == 2)
    }

    @Test
    func `ledger document parsing propagates cancellation`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let fileURL = environment.root.appendingPathComponent("rollout-without-owner.jsonl")
        try Self.tokenCountLine(
            timestamp: "2026-07-09T12:00:00Z",
            last: (input: 100, cached: 0, output: 10),
            total: (input: 100, cached: 0, output: 10))
            .write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.parseCodexLineageDocument(
                fileURL: fileURL,
                checkCancellation: { throw CancellationError() })
        }
    }

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
    func `copy stable identities preserve independent equal observations`() throws {
        let copied = Self.observation(
            eventID: "turn-a:0", timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100)
        let independent = Self.observation(
            eventID: "turn-b:0", timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100)
        let report = try CodexLineageLedger.reconcile(
            documents: [
                Self.document(owner: "root", observations: [copied]),
                Self.document(owner: "child", parent: "root", observations: [copied, independent]),
            ],
            localTimeZone: .gmt)

        #expect(report.utcDays["2026-07-09"]?.input == 200)
        #expect(report.acceptedObservationCount == 2)
        #expect(report.duplicateObservationCount == 1)
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
    func `parser ordinals do not revive an unchanged same turn state`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let fileURL = environment.root.appendingPathComponent("rollout-2026-07-09T12-00-00-root.jsonl")
        let metadata = """
        {"timestamp":"2026-07-09T12:00:00Z","type":"session_meta","payload":{"id":"root"}}
        {"timestamp":"2026-07-09T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
        """
        let tokenState = Self.tokenCountLine(
            timestamp: "2026-07-09T12:01:00Z",
            last: (input: 100, cached: 40, output: 10),
            total: (input: 100, cached: 40, output: 10))
        try "\(metadata)\n\(tokenState)\n\(tokenState)"
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let document = try CostUsageScanner.parseCodexLineageDocument(fileURL: fileURL)
        #expect(document.observations.map(\.eventID) == ["turn-a:0", "turn-a:1"])
        let report = try CodexLineageLedger.reconcile(documents: [document], localTimeZone: .gmt)

        #expect(report.utcDays["2026-07-09"]?.input == 100)
        #expect(report.acceptedObservationCount == 1)
        #expect(report.duplicateObservationCount == 1)
    }

    @Test
    func `matching event hints with different token states remain distinct`() throws {
        let first = Self.observation(
            eventID: "turn-a:0", timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100)
        let forked = Self.observation(
            eventID: "turn-a:0", timestamp: "2026-07-09T12:01:00Z", input: 25, totalInput: 125)
        let report = try CodexLineageLedger.reconcile(
            documents: [Self.document(owner: "root", observations: [first, forked])],
            localTimeZone: .gmt)

        #expect(report.utcDays["2026-07-09"]?.input == 125)
        #expect(report.acceptedObservationCount == 2)
        #expect(report.duplicateObservationCount == 0)
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
        eventID: String? = nil,
        timestamp: String,
        input: Int,
        cached: Int = 0,
        output: Int = 0,
        totalInput: Int) -> CodexLineageLedger.Observation
    {
        .init(
            eventID: eventID,
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

    private static func tokenCountLine(
        timestamp: String,
        last: (input: Int, cached: Int, output: Int),
        total: (input: Int, cached: Int, output: Int)) -> String
    {
        #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"#
            + #""last_token_usage":{"input_tokens":\#(last.input),"cached_input_tokens":\#(last.cached),"#
            + #""output_tokens":\#(last.output)},"total_token_usage":{"input_tokens":\#(total.input),"#
            + #""cached_input_tokens":\#(total.cached),"output_tokens":\#(total.output)}}}}"#
    }
}
