import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityStepUUIDConsistencyTests {
    private typealias Fixture = AntigravityLocalFixture

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
}
