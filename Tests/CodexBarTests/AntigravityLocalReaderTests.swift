import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct AntigravityLocalReaderTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test
    func `literal synthetic schema example has independently calculated counts and time`() async throws {
        // Handwritten bytes, not a round-trip through the fixture encoder.
        // Pinned upstream fields: input 11 + 100, cache 50, text 30, thinking 7 = 198.
        let bytes: [UInt8] = [
            0x0A, 0x1B, 0x22, 0x0A, 0x08, 0x0B, 0x10, 0x64, 0x28, 0x32, 0x48, 0x1E, 0x50, 0x07,
            0x4A, 0x0D, 0x22, 0x0B, 0x08, 0xC0, 0xCD, 0xC0, 0xD4, 0x06, 0x10, 0x80, 0xE5, 0x9A, 0x77,
        ]
        let fixture = try Fixture()
        try fixture.database(blobs: [bytes])
        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.data.first?.date == "2026-08-27")
        #expect(report.report.data.first?.inputTokens == 111)
        #expect(report.report.data.first?.outputTokens == 30)
        #expect(report.report.data.first?.cacheReadTokens == 50)
        #expect(report.report.data.first?.cacheCreationTokens == 0)
        #expect(report.report.data.first?.reasoningTokens == 7)
        #expect(report.report.data.first?.modelBreakdowns?.first?.modelName == "unknown")
        #expect(try await fixture.snapshot().last30DaysTokens == 198)
    }

    @Test
    func `empty optional model metadata remains absent`() async throws {
        let fixture = try Fixture()
        let blob = Fixture.blob(model: "", label: "  ")
        let turn = try #require(try AntigravityProtoReader.parseTurn(blob))
        #expect(turn.model == nil)
        #expect(turn.label == nil)
        try fixture.database(blobs: [blob, Fixture.blob(model: "fixture-model-b", label: "")])
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.first?.modelBreakdowns?.map(\.modelName) == ["unknown", "fixture-model-b"])
    }

    @Test
    func `malformed earlier embedded envelope cannot be hidden by a valid later envelope`() throws {
        let malformed = Fixture.message(1, [0x22, 0x80])
        #expect(try AntigravityProtoReader.parseTurn(malformed + Fixture.blob()) == nil)
    }

    @Test
    func `shared token mix overflow cannot revive on a third day`() throws {
        var mix = CostUsageTokenMix(inputTokens: Int.max - 1, outputTokens: 2)
        mix.merge(CostUsageTokenMix(inputTokens: 2, outputTokens: 3))
        mix.merge(CostUsageTokenMix(inputTokens: 7, outputTokens: 4))
        #expect(mix.inputTokens == nil)
        #expect(mix.outputTokens == 9)
        var receiver = CostUsageTokenMix(inputTokens: 4)
        receiver.merge(mix)
        #expect(receiver.inputTokens == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(mix)) as? [String: Any])
        #expect(object["overflowedClasses"] == nil)
        var absent = CostUsageTokenMix()
        absent.merge(CostUsageTokenMix(inputTokens: 8))
        absent.merge(CostUsageTokenMix())
        #expect(absent.inputTokens == 8)
    }

    @Test
    func `production discovery report and fetcher retain independent token counts without pricing`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(response: "a"), Fixture.blob(response: "b")])
        try fixture.database("session-b", rootIndex: 1, blobs: [
            Fixture.blob(model: nil, response: "a"), Fixture.blob(response: "b"),
        ])
        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 792) // 4 × (11 + 100 + 30 + 50 + 7)
        #expect(report.report.data.first?.requestCount == 4)
        #expect(report.report.data.first?.modelBreakdowns?.first?.requestCount == 4)
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.last30DaysTokens == 792)
        #expect(snapshot.sessionTokens == 792)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.sessionCostUSD == nil)
        #expect(snapshot.costProvenance == .unknown)
        #expect(snapshot.daily.allSatisfy { $0.costUSD == nil })
        #expect(snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.allSatisfy { $0.costUSD == nil })
    }

    @Test
    func `modern opaque timestamp rows use the trusted session creation time`() async throws {
        let fixture = try Fixture()
        #expect(try AntigravityProtoReader.parseTurn(Fixture.modernBlob())?.timestampMs == nil)
        try fixture.database(
            blobs: [Fixture.modernBlob()],
            createdSeconds: UInt64(Fixture.now.timeIntervalSince1970))

        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 198)
        #expect(report.report.data.first?.inputTokens == 111)
        #expect(report.report.data.first?.outputTokens == 30)
        #expect(report.report.data.first?.cacheReadTokens == 50)
        #expect(report.report.data.first?.cacheCreationTokens == 0)
        #expect(report.report.data.first?.reasoningTokens == 7)
        #expect(report.report.data.first?.date == "2026-08-27")

        let snapshot = try await fixture.snapshot()
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == 198)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    @Test
    func `modern rows without a trusted session timestamp remain partial`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.modernBlob()])

        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.report.summary == nil)
    }

    @Test
    func `legacy event timestamps take precedence over session creation time`() throws {
        let fixture = try Fixture()
        try fixture.database(
            blobs: [Fixture.blob(seconds: UInt64(Fixture.now.timeIntervalSince1970) - 86400)],
            createdSeconds: UInt64(Fixture.now.timeIntervalSince1970))

        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.data.first?.date == "2026-08-26")
    }

    @Test
    func `unrecognized generation timestamp shapes produce partial coverage`() throws {
        let fixture = try Fixture()
        let wrongMarker = Fixture.modernBlob(
            response: "unrecognized-timestamp-shape",
            timestampMarker: 2,
            timestampPayload: [1, 2, 3, 4, 5, 6, 7, 8])
        let shortPayload = Fixture.modernBlob(
            response: "short-timestamp-payload",
            timestampPayload: [1, 2, 3, 4, 5, 6, 7])
        let longPayload = Fixture.modernBlob(
            response: "long-timestamp-payload",
            timestampPayload: [1, 2, 3, 4, 5, 6, 7, 8, 9])
        try fixture.database(
            blobs: [wrongMarker, shortPayload, longPayload],
            createdSeconds: UInt64(Fixture.now.timeIntervalSince1970))

        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.report.summary == nil)
    }

    @Test
    func `conversation aggregate rows do not invalidate generation history`() throws {
        let fixture = try Fixture()
        let usage = Fixture.message(4, Fixture.varint(1, 11))
        let aggregates = [1, 2].map { field in
            Fixture.message(1, Fixture.message(field, Fixture.varint(1, 1)) + usage)
        }
        try fixture.database(blobs: [Fixture.blob()] + aggregates)

        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 198)
    }

    @Test(arguments: [1, 2])
    func `wrong wire conversation fields produce partial coverage`(field: Int) throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.conversationMarkerBlob(marker: Fixture.varint(field, 1))])

        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.report.summary == nil)
    }

    @Test
    func `conversation marker with generation evidence remains token history`() throws {
        let fixture = try Fixture()
        try fixture.database(
            blobs: [Fixture.conversationMarkerBlob(includeGeneration: true)],
            createdSeconds: UInt64(Fixture.now.timeIntervalSince1970))

        let report = try fixture.report()
        #expect(report.coverage == .complete)
        let entry = try #require(report.report.data.first)
        #expect(entry.inputTokens == 111)
        #expect(entry.outputTokens == 30)
        #expect(entry.cacheReadTokens == 50)
        #expect(entry.cacheCreationTokens == 0)
        #expect(entry.reasoningTokens == 7)
    }

    @Test
    func `complete empty out of window absent and corrupt sources remain distinct`() async throws {
        let fixture = try Fixture()
        #expect(try fixture.report().coverage == .unavailable)
        #expect(try await !fixture.snapshot().historyCoverageIsEstablished)
        let url = try fixture.database()
        #expect(try fixture.report().coverage == .complete)
        #expect(try await fixture.snapshot().last30DaysTokens == 0)
        let database = try Fixture.open(url)
        try Fixture.insert(database, row: 0, blob: Fixture.blob(seconds: 1_600_000_000))
        sqlite3_close(database)
        let outside = try await fixture.snapshot()
        #expect(outside.daily.isEmpty)
        #expect(outside.historyCoverageIsEstablished)
        #expect(outside.last30DaysTokens == 0)
        try Data("not a database".utf8).write(to: url)
        #expect(try fixture.report().coverage == .partial)
        let corrupt = try await fixture.snapshot()
        #expect(!corrupt.historyCoverageIsEstablished)
        #expect(corrupt.sessionTokens == nil)
        #expect(corrupt.last30DaysTokens == nil)
    }

    @Test
    func `SQLite authority never permits smaller stale JSONL replacement`() async throws {
        let fixture = try Fixture()
        try fixture.jsonl([Fixture.cacheUsage])
        #expect(try await fixture.snapshot().last30DaysTokens == 180)
        try fixture.database(blobs: [Fixture.blob(), Fixture.blob()])
        #expect(try await fixture.snapshot().last30DaysTokens == 396)
        let invalid = try fixture.database("broken")
        try Data("broken".utf8).write(to: invalid)
        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.report.summary?.totalTokens == 396)
        let snapshot = try await fixture.snapshot()
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.last30DaysTokens == nil)
    }

    @Test
    func `one explicit environment preserves both recognized overrides`() async throws {
        let fixture = try Fixture()
        let relocated = fixture.root.appendingPathComponent("relocated-tokscale")
        try fixture.jsonl(
            [Fixture.cacheUsage], root: relocated.appendingPathComponent("antigravity-cache/sessions"))
        var environment = fixture.environment
        environment["TOKSCALE_CONFIG_DIR"] = relocated.path
        #expect(try await fixture.snapshot(environment: environment).last30DaysTokens == 180)
        let original = try fixture.database(blobs: [Fixture.blob()])
        let gemini = fixture.root.appendingPathComponent("relocated-gemini")
        let conversations = gemini.appendingPathComponent("antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: conversations.appendingPathComponent("session-a.db"))
        environment["GEMINI_CLI_HOME"] = gemini.path
        #expect(try await fixture.snapshot(environment: environment).last30DaysTokens == 198)
    }

    @Test
    func `discovery errors are partial and block fallback even alongside a healthy root`() async throws {
        let fixture = try Fixture()
        let root = fixture.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("directory replaced by file".utf8).write(to: root)
        try fixture.jsonl([Fixture.cacheUsage])
        #expect(try fixture.report().coverage == .partial)
        #expect(try await !fixture.snapshot().historyCoverageIsEstablished)
        try fixture.database("healthy", rootIndex: 1, blobs: [Fixture.blob()])
        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.report.summary?.totalTokens == 198)
    }

    @Test
    func `copied session rows deduplicate without dropping legitimate ID-less rows or cross-session IDs`() throws {
        let fixture = try Fixture()
        let blobs = [Fixture.blob(), Fixture.blob(), Fixture.blob(response: "same"), Fixture.blob(response: "same")]
        let original = try fixture.database(blobs: blobs)
        let root = fixture.context.databaseRoots[1]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: root.appendingPathComponent(original.lastPathComponent))
        try fixture.database("session-b", rootIndex: 2, blobs: [Fixture.blob(response: "same")])
        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 792)
        #expect(report.report.data.first?.requestCount == 4)
    }

    @Test
    func `invalid first copy cannot reserve identity and conflicting copies are partial`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(response: "response", seconds: nil)])
        try fixture.database(rootIndex: 1, blobs: [Fixture.blob(response: "response")])
        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.report.summary?.totalTokens == 198)
        try fixture.database(rootIndex: 2, blobs: [Fixture.blob(input: 200, response: "response")])
        #expect(try fixture.report().coverage == .partial)
    }

    @Test
    func `failed daily aggregation does not reserve a response needed by a later valid row`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [
            Fixture.blob(
                system: 0,
                input: UInt64(Int.max - 1),
                output: 0,
                cacheRead: 0,
                reasoning: 0,
                seconds: 1_787_745_600),
            Fixture.blob(
                system: 0,
                input: 2,
                output: 0,
                cacheRead: 0,
                reasoning: 0,
                response: "retry",
                seconds: 1_787_745_600),
            Fixture.blob(system: 0, input: 7, output: 0, cacheRead: 0, reasoning: 0, response: "retry"),
        ])
        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.report.data.count == 2)
        #expect(report.report.data.last?.inputTokens == 7)
        #expect(report.report.summary?.totalTokens == nil)
    }

    @Test
    func `label conflicts remain sticky and raw historical identities are not canonicalized`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [
            Fixture.blob(model: "fixture-historical-a"), Fixture.blob(model: "fixture-historical-b"),
            Fixture.blob(model: "fixture-historical-a"), Fixture.blob(model: nil),
        ])
        let report = try fixture.report()
        #expect(report.coverage == .complete)
        let breakdowns = try #require(report.report.data.first?.modelBreakdowns)
        #expect(breakdowns.map(\.modelName) == ["fixture-historical-a", "fixture-historical-b", "unknown"])
        #expect(breakdowns.map(\.requestCount) == [2, 1, 1])
    }

    @Test
    func `raw model conflicts are detected before display whitespace normalization`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [
            Fixture.blob(model: "fixture-a"), Fixture.blob(model: " fixture-a "),
            Fixture.blob(model: nil),
        ])
        let breakdowns = try #require(try fixture.report().report.data.first?.modelBreakdowns)
        #expect(breakdowns.map(\.modelName) == ["fixture-a", "unknown"])
        #expect(breakdowns.map(\.requestCount) == [2, 1])
    }

    @Test
    func `unreadable recognized directory does not disappear from coverage`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob()])
        try fixture.database("healthy", rootIndex: 1, blobs: [Fixture.blob()])
        try fixture.jsonl([Fixture.cacheUsage])
        let root = fixture.context.databaseRoots[0]
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.report.summary?.totalTokens == 198)
    }

    @Test
    func `copied JSONL uses explicit session identity and preserves separate ID-less turns`() throws {
        let fixture = try Fixture()
        let source = try fixture.jsonl([Fixture.cacheUsage, Fixture.cacheUsage])
        try FileManager.default.copyItem(
            at: source,
            to: source.deletingLastPathComponent().appendingPathComponent("copy.jsonl"))
        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 360)
        #expect(report.report.data.first?.requestCount == 2)
        let distinct = Fixture.cacheUsage.replacingOccurrences(of: "cache-session", with: "second-session")
        try fixture.jsonl([distinct], session: "second")
        #expect(try fixture.report().report.summary?.totalTokens == 540)
    }

    @Test
    func `repeated known messages merge scalar fields after validating every occurrence`() throws {
        let usage = Fixture.message(4, Fixture.varint(1, 11))
            + Fixture.message(4, Fixture.varint(2, 100))
        let time = Fixture.message(9, Fixture.message(4, Fixture.varint(1, 1_787_832_000)))
            + Fixture.message(9, Fixture.message(4, Fixture.varint(2, 123_000_000)))
        let bytes = Fixture.message(1, usage) + Fixture.message(1, time)
        let turn = try #require(try AntigravityProtoReader.parseTurn(bytes))
        #expect(turn.usage?.systemPrompt == 11)
        #expect(turn.usage?.newInput == 100)
        #expect(turn.timestampMs == 1_787_832_000_123)
        let fixture = try Fixture()
        try fixture.database(blobs: [bytes])
        #expect(try fixture.report().report.summary?.totalTokens == 111)
    }

    @Test(arguments: malformedBlobs)
    func `malformed or unsupported event layouts cannot establish coverage`(blob: [UInt8]) async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(), blob])
        #expect(try fixture.report().coverage == .partial)
        #expect(try await !fixture.snapshot().historyCoverageIsEstablished)
    }

    private static var malformedBlobs: [[UInt8]] {
        let valid = Fixture.blob()
        let timestamp = Fixture.message(9, Fixture.message(4, [0x10, 0x80]))
        return [
            Fixture.message(1, [0x22, 0x80]) + valid,
            Fixture.message(1, timestamp) + valid,
            Fixture.message(1, Fixture.message(9, Fixture.message(4, Fixture.varint(2, 1_000_000_000)))) + valid,
            Fixture.message(1, Fixture.message(19, [0xFF])) + valid,
            Fixture.message(1, Fixture.message(4, Fixture.varint(1, UInt64.max))) + valid,
            Fixture.message(1, Fixture.message(4, Fixture.varint(2, 4) + [0x5A, 0x80])),
            Fixture.message(1, Fixture.message(4, [0x08] + Array(repeating: 0xFF, count: 10))),
            Fixture.message(1, Fixture.varint(4, 1)) + valid,
            Fixture.message(1, [0]) + valid,
            Fixture.blob(seconds: nil),
            Fixture.blob(seconds: nil) + Fixture.message(
                1,
                Fixture.message(9, Fixture.message(10, [1, 2, 3, 4, 5, 6, 7, 8]))),
            Fixture.blob(system: UInt64(Int.max), input: 1),
        ]
    }

    @Test
    func `present invalid JSONL optional counter makes coverage incomplete`() async throws {
        for key in ["cacheRead", "cacheWrite", "reasoning"] {
            for invalid in [#""invalid""#, "null", "true", "-1", "1.5", "1e300"] {
                let fixture = try Fixture()
                let line = #"{"type":"usage","sessionId":"cache-session","input":10,"output":2,"#
                    + #""timestamp":1787832000250,"\#(key)":\#(invalid)}"#
                try fixture.jsonl([Fixture.cacheUsage, line])
                #expect(try fixture.report().coverage == .partial)
                #expect(try await !fixture.snapshot().historyCoverageIsEstablished)
            }
        }
    }

    @Test(arguments: ["1e300", "1787832000250.5", "true", "null", "-1"])
    func `invalid JSONL timestamps cannot trap or round into event dates`(timestamp: String) async throws {
        let fixture = try Fixture()
        let line = #"{"type":"usage","sessionId":"cache-session","input":10,"output":2,"timestamp":\#(timestamp)}"#
        try fixture.jsonl([line])
        #expect(try fixture.report().coverage == .partial)
        #expect(try await !fixture.snapshot().historyCoverageIsEstablished)
    }

    @Test
    func `JSONL producer metadata supplies session and model but never event time`() async throws {
        let fixture = try Fixture()
        try fixture.jsonl([
            #"{"type":"session_meta","sessionId":"cache-session","modelId":"fixture-cache","timestamp":1700000000000}"#,
            #"{"type":"usage","sessionId":"cache-session","input":10,"output":2,"#
                + #""timestamp":1787832000250,"modelId":""}"#,
        ])
        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 12)
        #expect(report.report.data.first?.modelBreakdowns?.first?.modelName == "fixture-cache")
        try fixture.jsonl([
            #"{"type":"session_meta","sessionId":"cache-session","timestamp":1787832000250}"#,
            Fixture.cacheUsage,
        ])
        let sameTimestamp = try fixture.report()
        #expect(sameTimestamp.coverage == .complete)
        #expect(sameTimestamp.report.summary?.totalTokens == 180)
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == 180)
        try fixture.jsonl([
            #"{"type":"session_meta","sessionId":"cache-session","timestamp":1787832000250}"#,
            #"{"type":"usage","sessionId":"cache-session","input":10,"output":2}"#,
        ])
        #expect(try fixture.report().coverage == .partial)
        #expect(try await !fixture.snapshot().historyCoverageIsEstablished)
    }

    @Test
    func `declared linked roots overrides and session files retain normal path semantics`() async throws {
        let fixture = try Fixture()
        let original = try fixture.database(blobs: [Fixture.blob()])
        let external = fixture.root.appendingPathComponent("owned-source")
        try FileManager.default.moveItem(at: original.deletingLastPathComponent(), to: external)
        try FileManager.default.createSymbolicLink(
            at: original.deletingLastPathComponent(), withDestinationURL: external)
        #expect(try await fixture.snapshot().last30DaysTokens == 198)
        let linkedFile = fixture.root.appendingPathComponent("owned-session-data")
        try FileManager.default.moveItem(at: external.appendingPathComponent("session-a.db"), to: linkedFile)
        try FileManager.default.createSymbolicLink(
            at: external.appendingPathComponent("session-a.db"), withDestinationURL: linkedFile)
        #expect(try await fixture.snapshot().last30DaysTokens == 198)
        let linkedGemini = fixture.root.appendingPathComponent("linked-gemini")
        try FileManager.default.createSymbolicLink(
            at: linkedGemini, withDestinationURL: fixture.root.appendingPathComponent(".gemini"))
        var linkedEnvironment = fixture.environment
        linkedEnvironment["GEMINI_CLI_HOME"] = linkedGemini.path
        #expect(try await fixture.snapshot(environment: linkedEnvironment).last30DaysTokens == 198)

        let cache = try Fixture()
        let cacheFile = try cache.jsonl([Fixture.cacheUsage])
        let linkedConfig = cache.root.appendingPathComponent("linked-config")
        try FileManager.default.createSymbolicLink(
            at: linkedConfig, withDestinationURL: cache.root.appendingPathComponent(".config/tokscale"))
        let dataFile = cache.root.appendingPathComponent("owned-session-data")
        try FileManager.default.moveItem(at: cacheFile, to: dataFile)
        try FileManager.default.createSymbolicLink(at: cacheFile, withDestinationURL: dataFile)
        var environment = cache.environment
        environment["TOKSCALE_CONFIG_DIR"] = linkedConfig.path
        #expect(try await cache.snapshot(environment: environment).last30DaysTokens == 180)
    }

    @Test
    func `one-shot caller Cocoa and POSIX cancellation errors preserve their original cause`() throws {
        for domain in [NSCocoaErrorDomain, NSPOSIXErrorDomain] {
            let fixture = try Fixture()
            let path = try fixture.jsonl([Fixture.cacheUsage])
            let expected = NSError(domain: domain, code: 9876)
            var checks = 0
            let budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {
                checks += 1
                if checks == 2 { throw expected }
            })
            do {
                _ = try AntigravityLocalReader.readJSONL([path], budget: budget)
                Issue.record("Caller cancellation was swallowed")
            } catch {
                #expect((error as NSError) === expected)
            }
            #expect(checks == 2)
        }
    }

    @Test
    func `empty JSONL requires recognized session metadata to establish empty history`() async throws {
        let fixture = try Fixture()
        try fixture.jsonl([])
        #expect(try await !fixture.snapshot().historyCoverageIsEstablished)
        try fixture.jsonl([#"{"type":"session_meta","sessionId":"empty","modelId":null,"timestamp":null}"#])
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.last30DaysTokens == 0)
    }

    @Test
    func `JSONL output and thinking relationship is unsupported without independent schema evidence`() async throws {
        let fixture = try Fixture()
        // The pinned producer maps outputTokens=5 and thinkingOutputTokens=1 separately but does not prove overlap.
        // Do not manufacture either a 17-token or an 18-token exact total from these named fields.
        let usage = #"{"type":"usage","sessionId":"producer-example","input":10,"output":5,"#
            + #""cacheRead":2,"reasoning":1,"timestamp":1787832000250}"#
        try fixture.jsonl([usage])
        #expect(try fixture.report().coverage == .partial)
        let snapshot = try await fixture.snapshot()
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == nil)
    }
}
