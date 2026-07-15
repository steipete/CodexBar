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
            #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
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
        #expect(document.observations[0].model == "gpt-5.4")
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
    func `daily rows preserve model token and pricing dimensions`() throws {
        let priced = Self.observation(
            timestamp: "2026-07-10T02:00:00Z",
            model: "gpt-5.4",
            input: 100,
            cached: 40,
            output: 10,
            totalInput: 100)
        let unpriced = Self.observation(
            timestamp: "2026-07-10T03:00:00Z",
            model: "future-model",
            input: 50,
            output: 5,
            totalInput: 150)

        let report = try CodexLineageLedger.reconcile(
            documents: [Self.document(owner: "root", observations: [priced, unpriced])],
            localTimeZone: #require(TimeZone(identifier: "America/New_York")))

        #expect(report.utcRows.map(\.day) == ["2026-07-10", "2026-07-10"])
        #expect(report.localRows.map(\.day) == ["2026-07-09", "2026-07-09"])
        #expect(report.utcRows[0].model == "future-model")
        #expect(report.utcRows[0].totals == .init(input: 50, cached: 0, output: 5))
        #expect(report.utcRows[0].isPriced == false)
        #expect(report.utcRows[1].model == "gpt-5.4")
        #expect(report.utcRows[1].isPriced)
        #expect(report.utcRows[1].costUSD != nil)
    }

    @Test
    func `token event model overrides older turn context`() throws {
        let environment = try CostUsageTestEnvironment()
        let ownerID = "11111111-1111-4111-8111-111111111111"
        let file = environment.codexSessionsRoot.appendingPathComponent(
            "rollout-2026-07-09T12-00-00-\(ownerID).jsonl")
        let contents = [
            #"{"type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            Self.tokenCountLine(
                timestamp: "2026-07-09T12:00:00Z",
                model: "gpt-5.4",
                last: (input: 100, cached: 40, output: 10),
                total: (input: 100, cached: 40, output: 10)),
        ].joined(separator: "\n")
        try FileManager.default.createDirectory(at: environment.codexSessionsRoot, withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let document = try CostUsageScanner.parseCodexLineageDocument(fileURL: file)

        #expect(document.observations.map(\.model) == ["gpt-5.4"])
    }

    @Test
    func `equal-time duplicate prefers attributed model deterministically`() throws {
        let unknown = Self.observation(timestamp: "2026-07-10T03:00:00Z", input: 50, totalInput: 50)
        let attributed = Self.observation(
            timestamp: "2026-07-10T03:00:00Z",
            model: "gpt-5.4",
            input: 50,
            totalInput: 50)

        let report = try CodexLineageLedger.reconcile(
            documents: [
                Self.document(owner: "child", parent: "root", observations: [unknown]),
                Self.document(owner: "root", observations: [attributed]),
            ],
            localTimeZone: .gmt)

        #expect(report.acceptedObservationCount == 1)
        #expect(report.utcRows.map(\.model) == ["gpt-5.4"])
        #expect(report.utcRows[0].isPriced)
    }

    @Test
    func `daily rows price long context observations independently`() throws {
        let first = Self.observation(
            timestamp: "2026-07-10T03:00:00Z",
            model: "gpt-5.4",
            input: 272_001,
            cached: 100_000,
            output: 5,
            totalInput: 272_001)
        let second = Self.observation(
            timestamp: "2026-07-10T04:00:00Z",
            model: "gpt-5.4",
            input: 100,
            output: 5,
            totalInput: 272_101)
        let expected = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 272_001,
            cachedInputTokens: 100_000,
            outputTokens: 5)) + #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 5))

        let report = try CodexLineageLedger.reconcile(
            documents: [Self.document(owner: "root", observations: [first, second])],
            localTimeZone: .gmt)

        #expect(try abs(#require(report.utcRows.first?.costUSD) - expected) < 0.000001)
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
    func `different event ordinals do not revive an unchanged owner state`() throws {
        let first = Self.observation(
            eventID: "turn-a:0", timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100)
        let repeated = Self.observation(
            eventID: "turn-a:1", timestamp: "2026-07-09T12:01:00Z", input: 100, totalInput: 100)
        let report = try CodexLineageLedger.reconcile(
            documents: [Self.document(owner: "root", observations: [first, repeated])],
            localTimeZone: .gmt)

        #expect(report.utcDays["2026-07-09"]?.input == 100)
        #expect(report.acceptedObservationCount == 1)
        #expect(report.duplicateObservationCount == 1)
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
        model: String = CostUsagePricing.codexUnattributedModel,
        input: Int,
        cached: Int = 0,
        output: Int = 0,
        totalInput: Int) -> CodexLineageLedger.Observation
    {
        .init(
            eventID: eventID,
            timestamp: timestamp,
            model: model,
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
        model: String? = nil,
        last: (input: Int, cached: Int, output: Int),
        total: (input: Int, cached: Int, output: Int)) -> String
    {
        let modelJSON = model.map { #", "model":"\#($0)""# } ?? ""
        return #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"#
            + #""last_token_usage":{"input_tokens":\#(last.input),"cached_input_tokens":\#(last.cached),"#
            + #""output_tokens":\#(last.output)},"total_token_usage":{"input_tokens":\#(total.input),"#
            + #""cached_input_tokens":\#(total.cached),"output_tokens":\#(total.output)}\#(modelJSON)}}}"#
    }
}
