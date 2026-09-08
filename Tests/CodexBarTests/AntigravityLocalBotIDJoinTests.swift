import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct AntigravityLocalBotIDJoinTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test
    func `bot ID exact join recovers turns when step counts mismatch`() throws {
        let fixture = try Fixture()
        let stepUUID = "shared-session-uuid"
        let first = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-aaa", seconds: nil)
        let second = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-bbb", seconds: nil)
        // An auxiliary step must not take the later generation's timestamp slot.
        let firstStep = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-aaa", seconds: 1_787_875_140)
        let extraStep = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-inflight", seconds: 1_787_875_200)
        let secondStep = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-bbb", seconds: 1_787_875_260)
        let url = try fixture.database(blobs: [first, second], stepBlobs: [firstStep, extraStep, secondStep])

        let source = try AntigravityLocalReader.readDatabases(
            [url], budget: .init(limits: .init(), cancellation: {}))
        let report = try fixture.report()

        #expect(source.events.map(\.row) == [0, 1])
        #expect(source.events.map(\.turn.timestampMs) == [1_787_875_140_250, 1_787_875_260_250])
        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-27", "2026-08-28"])
    }

    @Test
    func `bot ID exact join ignores step idx order`() throws {
        let fixture = try Fixture()
        let stepUUID = "shared-session-uuid"
        let first = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-aaa", seconds: nil)
        let second = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-bbb", seconds: nil)
        // Steps stored in reverse idx order: positional prefix would misattribute dates.
        let url = try fixture.database(blobs: [first, second])
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, "CREATE TABLE steps (idx INTEGER, metadata BLOB)")
        try Fixture.insertStep(
            database,
            row: 20,
            blob: Fixture.stepMetadataBlob(stepUUID: stepUUID, botID: "bot-aaa", seconds: 1_787_875_140))
        try Fixture.insertStep(
            database,
            row: 10,
            blob: Fixture.stepMetadataBlob(stepUUID: stepUUID, botID: "bot-bbb", seconds: 1_787_875_260))

        let source = try AntigravityLocalReader.readDatabases(
            [url], budget: .init(limits: .init(), cancellation: {}))
        let report = try fixture.report()

        #expect(source.events.map(\.row) == [0, 1])
        #expect(source.events.map(\.turn.timestampMs) == [1_787_875_140_250, 1_787_875_260_250])
        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-27", "2026-08-28"])
    }

    @Test
    func `conflicting duplicate bot IDs fail closed`() throws {
        let fixture = try Fixture()
        let stepUUID = "shared-session-uuid"
        let turn = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-dup", seconds: nil)
        let first = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-dup", seconds: 1_787_875_140)
        let second = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-dup", seconds: 1_787_875_260)
        try fixture.database(blobs: [turn], stepBlobs: [first, second])

        let report = try fixture.report()

        #expect(report.coverage == .partial)
        #expect(report.report.data.isEmpty)
    }

    @Test
    func `duplicate bot IDs with identical timestamps still recover`() throws {
        let fixture = try Fixture()
        let stepUUID = "shared-session-uuid"
        let turn = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-retry", seconds: nil)
        // Retried step writes agree on the timestamp: idempotent, not ambiguous.
        let first = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-retry", seconds: 1_787_875_140)
        let second = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-retry", seconds: 1_787_875_140)
        try fixture.database(blobs: [turn], stepBlobs: [first, second])

        let report = try fixture.report()

        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-27"])
    }

    @Test
    func `embedded timestamp takes precedence over bot ID join`() throws {
        let fixture = try Fixture()
        let stepUUID = "legacy-step-uuid"
        let turn = Fixture.blobWithRootEnvelope(
            stepUUID: stepUUID, botID: "bot-legacy", seconds: 1_787_875_140)
        let step = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-legacy", seconds: 1_787_875_260)
        try fixture.database(blobs: [turn], stepBlobs: [step])

        let report = try fixture.report()

        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-27"])
    }

    @Test
    func `bot ID without matching step falls back to positional recovery`() throws {
        let fixture = try Fixture()
        let stepUUID = "mixed-write-step-uuid"
        let turn = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-new", seconds: nil)
        // Step rows predate bot ID writes: no exact key, positional still applies.
        let step = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_875_140)
        try fixture.database(blobs: [turn], stepBlobs: [step])

        let report = try fixture.report()

        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-27"])
    }

    @Test
    func `malformed step bot ID falls back without failing the scan`() throws {
        let fixture = try Fixture()
        let stepUUID = "mixed-bot-step-uuid"
        let turn = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-aaa", seconds: nil)
        // Non-UTF8 bot ID bytes: the step stays positionally usable, exact join uses the valid row.
        let malformed = Fixture.message(1, Fixture.varint(1, 1_787_875_140) + Fixture.varint(2, 0))
            + Fixture.message(9, Fixture.message(7, [0xFF, 0xFE]))
            + Fixture.message(12, Array(stepUUID.utf8))
        let step = Fixture.stepMetadataBlob(stepUUID: stepUUID, botID: "bot-aaa", seconds: 1_787_875_260)
        try fixture.database(blobs: [turn], stepBlobs: [malformed, step])

        let report = try fixture.report()

        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-28"])
    }

    @Test
    func `missing bot ID falls back to positional recovery`() throws {
        let fixture = try Fixture()
        let stepUUID = "fallback-step-uuid"
        let turn = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, seconds: nil)
        let step = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_875_140)
        try fixture.database(blobs: [turn], stepBlobs: [step])

        let report = try fixture.report()

        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-27"])
    }

    @Test
    func `interactive session shape with content envelopes recovers via bot ID`() throws {
        // Mirrors a live agy interactive session row: the root carries extra envelopes
        // (fields 3/8) and the chat carries large content envelopes (fields 1/2/8) with
        // usage but no embedded timestamp; the generation envelope holds only the
        // context-meter sentinel and meter. A non-generation step shares the table.
        let fixture = try Fixture()
        let stepUUID = "live-session-uuid"
        let botID = "bot-live-1"
        let usage = Fixture.varint(1, 1318) + Fixture.varint(2, 15669) + Fixture.varint(9, 123)
            + Fixture.varint(10, 27) + Fixture.message(7, Array(botID.utf8))
        var chat = Fixture.message(1, [UInt8](repeating: 0x61, count: 24775))
        chat += Fixture.message(2, [UInt8](repeating: 0x62, count: 433))
        chat += Fixture.message(4, usage)
        chat += Fixture.message(
            9, Fixture.varint(2, UInt64.max) + Fixture.message(10, Fixture.varint(1, 255_523)))
        chat += Fixture.message(8, [UInt8](repeating: 0x63, count: 2362))
        var root = Fixture.message(2, [0x01])
        root += Fixture.message(3, [UInt8](repeating: 0x64, count: 3020))
        root += Fixture.message(4, Array(stepUUID.utf8))
        root += Fixture.message(8, [UInt8](repeating: 0x65, count: 424))
        root += Fixture.message(1, chat)
        let otherStep = Fixture.message(1, Fixture.varint(1, 1_787_875_140) + Fixture.varint(2, 0))
            + Fixture.varint(3, 4) + Fixture.message(12, Array(stepUUID.utf8))
        let step = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: botID, seconds: 1_787_875_260)
        try fixture.database(blobs: [root], stepBlobs: [otherStep, step])

        let report = try fixture.report()

        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-28"])
    }

    @Test
    func `structurally malformed step bot ID keeps row positionally usable`() throws {
        let fixture = try Fixture()
        let stepUUID = "mixed-shape-step-uuid"
        let turn = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-aaa", seconds: nil)
        // Field 9 with the wrong wire type: no exact key, but the row still counts positionally.
        let malformed = Fixture.message(1, Fixture.varint(1, 1_787_875_140) + Fixture.varint(2, 0))
            + Fixture.varint(9, 1)
            + Fixture.message(12, Array(stepUUID.utf8))
        let step = Fixture.stepMetadataBlob(stepUUID: stepUUID, botID: "bot-aaa", seconds: 1_787_875_260)
        try fixture.database(blobs: [turn], stepBlobs: [malformed, step])

        let report = try fixture.report()

        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-28"])
    }

    @Test
    func `repeated generation bot ID skips exact matching but keeps positional guard`() throws {
        let fixture = try Fixture()
        let stepUUID = "reused-bot-step-uuid"
        let first = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-dup", seconds: nil)
        let second = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-dup", seconds: nil)
        let firstStep = Fixture.stepMetadataBlob(stepUUID: stepUUID, botID: "bot-dup", seconds: 1_787_875_140)
        let secondStep = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_875_260)
        try fixture.database(blobs: [first, second], stepBlobs: [firstStep, secondStep])

        let report = try fixture.report()

        // Exact matching is withheld for the reused identity; the guarded positional path
        // still dates each turn instead of stamping both with the first timestamp.
        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-08-27", "2026-08-28"])
    }

    @Test
    func `conflicted bot ID rows stay out of positional matching`() throws {
        let fixture = try Fixture()
        let stepUUID = "leak-step-uuid"
        let conflicted = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, botID: "bot-dup", seconds: nil)
        let plain = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, seconds: nil)
        let first = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-dup", seconds: 1_787_875_140)
        let second = Fixture.stepMetadataBlob(
            stepUUID: stepUUID, botID: "bot-dup", seconds: 1_787_875_180)
        let third = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_875_260)
        let fourth = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_875_320)
        try fixture.database(blobs: [conflicted, plain], stepBlobs: [first, second, third, fourth])

        let report = try fixture.report()

        // Ambiguous steps must retain their slots; removing them can shift unrelated turns.
        #expect(report.coverage == .partial)
        #expect(report.report.data.isEmpty)
    }
}
