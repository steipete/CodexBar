import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityStepUUIDConsistencyTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test(arguments: [false, true], [UInt64?(1_787_875_140), 1_787_875_260, nil])
    func `UUID-less duplicate bot IDs cannot establish an exact date`(
        unidentifiedFirst: Bool, unidentifiedSeconds: UInt64?) throws
    {
        let fixture = try Fixture()
        let stepUUID = "identified-uuid"
        let botID = "shared-bot"
        let turn = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: botID, seconds: nil)
        let matching = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: botID, seconds: 1_787_875_140, nanos: 0)
        let unidentified = if let unidentifiedSeconds {
            Fixture.stepMetadataBlob(stepUUID: nil, botID: botID, seconds: unidentifiedSeconds, nanos: 0)
        } else {
            Fixture.message(9, Fixture.message(7, Array(botID.utf8)))
        }
        let url = try fixture.database(
            blobs: [turn], stepBlobs: unidentifiedFirst ? [unidentified, matching] : [matching, unidentified])
        let budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {})
        let source = try AntigravityLocalReader.readDatabases([url], budget: budget)
        #expect(!source.isComplete)
        #expect(source.events.isEmpty)
        #expect(try fixture.report().coverage == .partial)
    }

    @Test(arguments: [false, true])
    func `pure UUID evidence must agree with embedded generation timestamps`(conflicting: Bool) throws {
        let fixture = try Fixture()
        let stepUUID = "pure-uuid-embedded-agreement"
        let generations = [
            Fixture.blobWithRootEnvelope(
                stepUUID: stepUUID,
                input: 100,
                seconds: 1_787_875_100),
            Fixture.blobWithRootEnvelope(
                stepUUID: stepUUID,
                input: 200,
                seconds: nil),
        ]
        let steps = [
            Fixture.stepMetadataBlob(
                stepUUID: stepUUID,
                seconds: conflicting ? 1_787_875_200 : 1_787_875_100,
                nanos: 250_000_000),
            Fixture.stepMetadataBlob(
                stepUUID: stepUUID,
                seconds: 1_787_875_300,
                nanos: 0),
        ]
        let url = try fixture.database(
            blobs: generations,
            stepBlobs: steps)
        let budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {})

        let source = try AntigravityLocalReader.readDatabases([url], budget: budget)
        let report = try fixture.report()

        #expect(source.isComplete == !conflicting)
        #expect(source.events.map(\.row) == (conflicting ? [0] : [0, 1]))
        #expect(source.events.map(\.turn.timestampMs) == (conflicting
                ? [1_787_875_100_250]
                : [1_787_875_100_250, 1_787_875_300_000]))
        #expect(report.coverage == (conflicting ? .partial : .complete))
    }

    @Test(arguments: [false, true])
    func `UUID-less step rows do not invalidate timestamp recovery`(uuidLessRowFirst: Bool) throws {
        let fixture = try Fixture()
        let stepUUID = "recoverable-step-uuid"
        let generations = [
            Fixture.blobWithRootEnvelope(
                stepUUID: stepUUID,
                input: 100,
                seconds: nil),
        ]
        let matchingStep = Fixture.stepMetadataBlob(
            stepUUID: stepUUID,
            seconds: 1_787_875_100,
            nanos: 250_000_000)
        let uuidLessStep = Fixture.stepMetadataBlob(
            stepUUID: nil,
            seconds: 1_787_874_000,
            nanos: 0)
        let steps = uuidLessRowFirst ? [uuidLessStep, matchingStep] : [matchingStep, uuidLessStep]
        let url = try fixture.database(
            blobs: generations,
            stepBlobs: steps)
        let budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {})

        let source = try AntigravityLocalReader.readDatabases([url], budget: budget)
        let report = try fixture.report()

        #expect(source.isComplete == true)
        #expect(source.events.map(\.row) == [0])
        #expect(source.events.map(\.turn.timestampMs) == [1_787_875_100_250])
        #expect(report.coverage == .complete)
    }

    @Test(arguments: [0, 1, 2])
    func `reused step UUID recovers distinct timestamps despite an unidentified row`(
        unidentifiedPosition: Int) throws
    {
        let fixture = try Fixture()
        let stepUUID = "reused-uuid-with-unidentified-row"
        let generations = [
            Fixture.blobWithRootEnvelope(
                stepUUID: stepUUID,
                input: 100,
                seconds: nil),
            Fixture.blobWithRootEnvelope(
                stepUUID: stepUUID,
                input: 200,
                seconds: nil),
        ]
        let first = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_875_140, nanos: 0)
        let second = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_875_260, nanos: 0)
        let unidentified = Fixture.stepMetadataBlob(stepUUID: nil, seconds: 1_787_874_000, nanos: 0)
        var steps = [first, second]
        steps.insert(unidentified, at: unidentifiedPosition)
        let url = try fixture.database(
            blobs: generations,
            stepBlobs: steps)
        let budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {})

        let source = try AntigravityLocalReader.readDatabases([url], budget: budget)
        let report = try fixture.report()

        #expect(source.isComplete == true)
        #expect(source.events.map(\.row) == [0, 1])
        #expect(source.events.map(\.turn.timestampMs) == [1_787_875_140_000, 1_787_875_260_000])
        #expect(report.coverage == .complete)
    }

    @Test
    func `bot ID exact match recovers despite an unidentified step row`() throws {
        let fixture = try Fixture()
        let stepUUID = "bot-id-with-unidentified-row"
        let botID = "bot-uuid-less-mix"
        let turn = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: botID, seconds: nil)
        let matchingStep = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: botID, seconds: 1_787_875_140, nanos: 0)
        let unidentified = Fixture.stepMetadataBlob(stepUUID: nil, seconds: 1_787_874_000, nanos: 0)
        let url = try fixture.database(
            blobs: [turn],
            stepBlobs: [matchingStep, unidentified])
        let budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {})

        let source = try AntigravityLocalReader.readDatabases([url], budget: budget)
        let report = try fixture.report()

        #expect(source.isComplete == true)
        #expect(source.events.map(\.row) == [0])
        #expect(source.events.map(\.turn.timestampMs) == [1_787_875_140_000])
        #expect(report.coverage == .complete)
    }

    @Test
    func `reused step UUID with only one identified step row stays partial alongside an unidentified row`() throws {
        let fixture = try Fixture()
        let stepUUID = "reused-uuid-single-identified-row"
        let generations = [
            Fixture.blobWithRootEnvelope(
                stepUUID: stepUUID,
                input: 100,
                seconds: nil),
            Fixture.blobWithRootEnvelope(
                stepUUID: stepUUID,
                input: 200,
                seconds: nil),
        ]
        let identified = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_875_140, nanos: 0)
        let unidentified = Fixture.stepMetadataBlob(stepUUID: nil, seconds: 1_787_874_000, nanos: 0)
        let url = try fixture.database(
            blobs: generations,
            stepBlobs: [identified, unidentified])
        let budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {})

        let source = try AntigravityLocalReader.readDatabases([url], budget: budget)
        let report = try fixture.report()

        #expect(source.isComplete == false)
        #expect(source.events.isEmpty)
        #expect(report.coverage == .partial)
    }
}
