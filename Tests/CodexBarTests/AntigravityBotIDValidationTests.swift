import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityBotIDValidationTests {
    private typealias Fixture = AntigravityLocalFixture
    private static let early: UInt64 = 1_787_875_140
    private static let late: UInt64 = 1_787_875_260

    @Test
    func `embedded generations also participate in bot ID uniqueness`() throws {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [
            Fixture.blobWithRootEnvelope(botID: "shared", seconds: Self.early),
            Fixture.blobWithRootEnvelope(botID: "shared", seconds: nil),
        ], stepBlobs: [Fixture.stepMetadataBlob(botID: "shared", seconds: Self.late)])

        let source = try Self.read(url)

        #expect(!source.isComplete)
        #expect(source.events.map(\.row) == [0])
        #expect(source.events.map(\.turn.timestampMs) == [1_787_875_140_250])
    }

    @Test(arguments: [false, true])
    func `repeated generation IDs retain consistent positional evidence`(unrelatedUUID: Bool) throws {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [
            Fixture.blobWithRootEnvelope(
                stepUUID: unrelatedUUID ? nil : "step-uuid-1", botID: "shared", seconds: Self.early),
            Fixture.blobWithRootEnvelope(botID: "shared", seconds: nil),
        ], stepBlobs: [
            Fixture.stepMetadataBlob(seconds: Self.early),
            Fixture.stepMetadataBlob(botID: "shared", seconds: Self.late),
        ])

        let source = try Self.read(url)

        #expect(source.isComplete)
        #expect(source.events.map(\.turn.timestampMs) == [
            1_787_875_140_250, unrelatedUUID ? 1_787_875_140_250 : 1_787_875_260_250,
        ])
    }

    @Test(arguments: [false, true])
    func `exact step evidence must agree with embedded timestamps without requiring positional order`(
        conflicting: Bool) throws
    {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [
            Fixture.blobWithRootEnvelope(botID: "embedded", seconds: Self.early),
            Fixture.blobWithRootEnvelope(botID: "pending", seconds: nil),
        ], stepBlobs: [
            Fixture.stepMetadataBlob(botID: "pending", seconds: Self.late),
            Fixture.stepMetadataBlob(botID: "embedded", seconds: conflicting ? Self.late : Self.early),
        ])

        let source = try Self.read(url)

        #expect(source.isComplete == !conflicting)
        #expect(source.events.first?.turn.timestampMs == 1_787_875_140_250)
        if conflicting {
            #expect(source.events.map(\.row) == [0])
        } else {
            #expect(source.events.map(\.row) == [0, 1])
            #expect(source.events.map(\.turn.timestampMs) == [1_787_875_140_250, 1_787_875_260_250])
        }
    }

    @Test(arguments: [false, true])
    func `embedded timestamps without exact identity evidence do not block reordered exact recovery`(
        hasUnmatchedID: Bool) throws
    {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [
            Fixture.blobWithRootEnvelope(botID: hasUnmatchedID ? "absent" : nil, seconds: Self.early),
            Fixture.blobWithRootEnvelope(botID: "pending", seconds: nil),
        ], stepBlobs: [
            Fixture.stepMetadataBlob(botID: "pending", seconds: Self.late),
            Fixture.stepMetadataBlob(seconds: Self.early),
        ])

        let source = try Self.read(url)

        #expect(source.isComplete)
        #expect(source.events.map(\.turn.timestampMs) == [1_787_875_140_250, 1_787_875_260_250])
    }

    @Test
    func `an unrelated UUID retains embedded timestamp precedence during exact recovery`() throws {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [
            Fixture.blobWithRootEnvelope(stepUUID: "complete", botID: "embedded", seconds: Self.early),
            Fixture.blobWithRootEnvelope(stepUUID: "recover", botID: "pending", seconds: nil),
        ], stepBlobs: [
            Fixture.stepMetadataBlob(stepUUID: "complete", botID: "embedded", seconds: Self.late),
            Fixture.stepMetadataBlob(stepUUID: "recover", botID: "pending", seconds: Self.late),
        ])

        let source = try Self.read(url)

        #expect(source.isComplete)
        #expect(source.events.map(\.turn.timestampMs) == [1_787_875_140_250, 1_787_875_260_250])
    }

    @Test(arguments: [false, true])
    func `ambiguous steps cannot compress positions or activate single timestamp sharing`(embedded: Bool) throws {
        let fixture = try Fixture()
        var steps = [
            Fixture.stepMetadataBlob(botID: "conflict", seconds: Self.early - 20),
            Fixture.stepMetadataBlob(botID: "conflict", seconds: Self.early - 10),
        ]
        if embedded {
            steps.append(Fixture.stepMetadataBlob(seconds: Self.early))
        }
        steps.append(Fixture.stepMetadataBlob(seconds: Self.late))
        let url = try fixture.database(blobs: [
            Fixture.blobWithRootEnvelope(seconds: embedded ? Self.early : nil),
            Fixture.blobWithRootEnvelope(seconds: nil),
        ], stepBlobs: steps)

        let source = try Self.read(url)

        #expect(!source.isComplete)
        #expect(source.events.map(\.row) == (embedded ? [0] : []))
    }

    @Test
    func `an exact ID owned by another UUID cannot fall back to positional evidence`() throws {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [
            Fixture.blobWithRootEnvelope(stepUUID: "local", botID: "owned-elsewhere", seconds: nil),
        ], stepBlobs: [
            Fixture.stepMetadataBlob(stepUUID: "local", seconds: Self.early),
            Fixture.stepMetadataBlob(stepUUID: "other", botID: "owned-elsewhere", seconds: Self.late),
        ])

        let source = try Self.read(url)

        #expect(!source.isComplete)
        #expect(source.events.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `timestamp less duplicate step IDs invalidate exact evidence in either order`(
        crossUUID: Bool,
        missingFirst: Bool) throws
    {
        let fixture = try Fixture()
        let valid = Fixture.stepMetadataBlob(stepUUID: "local", botID: "duplicate", seconds: Self.early)
        let missing = Fixture.message(9, Fixture.message(7, Array("duplicate".utf8)))
            + Fixture.message(12, Array((crossUUID ? "other" : "local").utf8))
        let url = try fixture.database(blobs: [
            Fixture.blobWithRootEnvelope(stepUUID: "local", botID: "duplicate", seconds: nil),
        ], stepBlobs: missingFirst ? [missing, valid] : [valid, missing])

        let source = try Self.read(url)

        #expect(!source.isComplete)
        #expect(source.events.isEmpty)
    }

    enum InvalidID: CaseIterable {
        case utf8
        case wire

        var field: [UInt8] {
            switch self {
            case .utf8: Fixture.message(7, [0xFF])
            case .wire: Fixture.varint(7, 1)
            }
        }
    }

    @Test(arguments: InvalidID.allCases, [false, true])
    func `invalid repeated step IDs stay invalid across envelopes`(_ invalid: InvalidID, invalidFirst: Bool) throws {
        let valid = Fixture.message(9, Fixture.message(7, Array("later-key".utf8)))
        let malformed = Fixture.message(9, invalid.field)
        let bytes = Fixture.stepMetadataBlob(seconds: Self.early)
            + (invalidFirst ? malformed + valid : valid + malformed)

        let parsed = try #require(try AntigravityProtoReader.parseStepMetadata(bytes))

        #expect(parsed.botID == nil)
        #expect(parsed.timestampMs == 1_787_875_140_250)
    }

    @Test(arguments: [false, true])
    func `a malformed step envelope cannot be repaired by a later valid ID`(invalidFirst: Bool) throws {
        let valid = Fixture.message(9, Fixture.message(7, Array("later-key".utf8)))
        let malformed = Fixture.message(9, [0x3A, 0x02, 0x61])
        let bytes = Fixture.stepMetadataBlob(seconds: Self.early)
            + (invalidFirst ? malformed + valid : valid + malformed)

        let parsed = try #require(try AntigravityProtoReader.parseStepMetadata(bytes))

        #expect(parsed.botID == nil)
        #expect(parsed.timestampMs == 1_787_875_140_250)
    }

    @Test(arguments: ["", " \n"])
    func `empty step ID scalars clear earlier values`(_ empty: String) throws {
        let bytes = Fixture.stepMetadataBlob(botID: "earlier", seconds: Self.early)
            + Fixture.message(9, Fixture.message(7, Array(empty.utf8)))

        #expect(try AntigravityProtoReader.parseStepMetadata(bytes)?.botID == nil)
    }

    @Test(arguments: ["", " \n"])
    func `empty generation ID scalars clear earlier values`(_ empty: String) throws {
        let bytes = Fixture.blobWithRootEnvelope(botID: "earlier", seconds: Self.early)
            + Fixture.message(1, Fixture.message(4, Fixture.message(7, Array(empty.utf8))))

        let turn = try #require(try AntigravityProtoReader.parseTurn(bytes))
        #expect(turn.usage?.botID == nil)
        #expect(turn.timestampMs == 1_787_875_140_250)
    }

    @Test(arguments: InvalidID.allCases, [false, true])
    func `malformed generation IDs preserve valid usage and remain invalid across envelopes`(
        _ invalid: InvalidID,
        invalidFirst: Bool) throws
    {
        let valid = Fixture.message(1, Fixture.message(4, Fixture.message(7, Array("later-key".utf8))))
        let malformed = Fixture.message(1, Fixture.message(4, invalid.field))
        let blob = Fixture.blobWithRootEnvelope(seconds: Self.early)
            + (invalidFirst ? malformed + valid : valid + malformed)
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [blob])

        let source = try Self.read(url)
        let turn = try #require(source.events.first?.turn)

        #expect(source.isComplete)
        #expect(turn.timestampMs == 1_787_875_140_250)
        #expect(turn.usage?.botID == nil)
        #expect(turn.usage?.newInput == 100)
    }

    @Test
    func `optional ID tolerance does not relax counters or protobuf framing`() throws {
        let base = Fixture.blobWithRootEnvelope(seconds: Self.early)
        let invalidCounter = Fixture.message(1, Fixture.message(4, Fixture.message(2, [1])))
        let truncatedUsage = Fixture.message(1, Fixture.message(4, [0x3A, 0x02, 0x61]))

        #expect(try AntigravityProtoReader.parseTurn(base + invalidCounter) == nil)
        #expect(try AntigravityProtoReader.parseTurn(base + truncatedUsage) == nil)
    }

    @Test(arguments: [false, true])
    func `malformed optional IDs do not turn equivalent copies into conflicts`(malformedFirst: Bool) throws {
        let fixture = try Fixture()
        let absent = Fixture.blobWithRootEnvelope(seconds: Self.early)
        let malformed = absent + Fixture.message(1, Fixture.message(4, InvalidID.utf8.field))
        try fixture.database(rootIndex: 0, blobs: [malformedFirst ? malformed : absent])
        try fixture.database(rootIndex: 1, blobs: [malformedFirst ? absent : malformed])

        let report = try fixture.report()

        #expect(report.coverage == .complete)
        #expect(report.report.data.count == 1)
        #expect(report.report.data.first?.totalTokens == 198)
    }

    private static func read(_ url: URL) throws -> AntigravityLocalReader.SourceResult {
        try AntigravityLocalReader.readDatabases([url], budget: .init(limits: .init(), cancellation: {}))
    }
}
