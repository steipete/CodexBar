import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CodexRequestSubtotalTests {
    private static let start: Int64 = 1_788_134_400_000
    private static let end: Int64 = 1_788_177_600_000

    private static func ledger(
        input: Int = 100, model: String? = "gpt-5", id: String = "a", output: Int = 10) -> CodexRequestLedger
    {
        self.source([self.accountingRow(id: id, model: model, input: input, output: output, reasoning: min(3, output))])
    }

    @Test
    func `current wire schema decodes an identified request`() throws {
        let wire = """
        {"schemaVersion":2,"provider":"codex","startUnixMs":\(Self.start),"endUnixMs":\(Self.end),
        "records":[{"id":"\(String(repeating: "a", count: 64))","timestampUnixMs":\(Self.end),
        "inputTokens":100,"cacheReadTokens":20,"outputTokens":10,"reasoningTokens":3,
        "model":"gpt-5","pricingMode":"standard","includedInPlan":false}],
        "conflictingIDs":[],"excludedCount":0,"partial":false}
        """
        let ledger = try JSONDecoder().decode(CodexRequestLedger.self, from: Data(wire.utf8))
        try ledger.validate(startUnixMs: Self.start, endUnixMs: Self.end)
        #expect(ledger.records.count == 1)
    }

    @Test
    func `local identified export enforces the emitted byte limit`() async throws {
        let ledger = Self.ledger()
        let remote = Self.source([Self.accountingRow(id: "b")])
        let accepted = try await CodexBarCLI.collectIdentifiedUsage(
            remotes: [],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            pretty: true,
            local: { ledger },
            fetchRemote: { _ in remote },
            makeMerger: { { try Self.price($0) } })
        #expect(accepted.localLedgerJSON != nil)
        #expect(accepted.reports.count == 1)
        #expect(accepted.reports[0].ledger?.records.count == 1)
        #expect(accepted.allSourcesAvailable)
        #expect(accepted.subtotal == nil)
        let envelope = try #require(CodexBarCLI.encodeJSON(accepted, pretty: false))
        let envelopeObject = try #require(
            JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        #expect(envelopeObject["localLedgerJSON"] == nil)

        let oversized = try Self.ledger(outputBytes: CodexRequestLedger.maximumOutputBytes + 1, pretty: true)
        let rejected = try await CodexBarCLI.collectIdentifiedUsage(
            remotes: ["fixture-host"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            pretty: true,
            local: { oversized },
            fetchRemote: { _ in remote },
            makeMerger: { { try Self.price($0) } })
        #expect(rejected.reports.count == 2)
        #expect(rejected.reports[0].ledger == nil)
        #expect(rejected.reports[0].error != nil)
    }

    @Test(arguments: [false, true], [
        CodexRequestLedger.maximumOutputBytes - 1,
        CodexRequestLedger.maximumOutputBytes,
        CodexRequestLedger.maximumOutputBytes + 1,
    ])
    func `identified ledger encoding bounds selected formatting and its newline`(
        pretty: Bool, outputBytes: Int) throws
    {
        let ledger = try Self.ledger(outputBytes: outputBytes, pretty: pretty)
        let json = CodexBarCLI.encodeJSON(ledger, pretty: pretty)
        let emittedBytes = json.map { $0.utf8.count + 1 } ?? 0

        #expect(emittedBytes == (outputBytes <= CodexRequestLedger.maximumOutputBytes ? outputBytes : 0))
    }

    @Test
    func `remote byte bound applies to received JSON rather than reencoding`() async throws {
        let remote = Self.source([Self.accountingRow(
            id: "b", model: String(repeating: "/", count: CodexRequestLedger.maximumOutputBytes / 2), mode: nil)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let wire = try #require(String(data: encoder.encode(remote), encoding: .utf8))
        #expect(wire.utf8.count < CodexRequestLedger.maximumOutputBytes)
        let fetcher = RemoteCodexCostFetcher(runner: { _, _ in wire })
        let report = try await CodexBarCLI.collectIdentifiedUsage(
            remotes: ["fixture-host"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: { Self.ledger() },
            fetchRemote: { host in
                try await fetcher.fetchIdentifiedUsage(
                    host: host, historyDays: 1, startUnixMs: Self.start, endUnixMs: Self.end)
            },
            makeMerger: { { try Self.price($0) } })
        #expect(report.allSourcesAvailable && !report.partial)
        #expect(report.subtotal?.requestCount == 2)
        #expect(report.subtotal?.totalTokens == 220)
    }

    @Test
    func `foreign legacy usage does not make Codex coverage partial`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata,
            #"{"type":"event_msg","timestamp":"2026-08-31T12:00:00Z","payload":{"type":"token_count","#
                + #""info":{"model":"kimi-coding/k2p5","total_token_usage":{"input_tokens":100,"output_tokens":10}}}}"#,
        ])
        #expect(ledger.excludedCount == 0)
        #expect(!ledger.partial)
    }

    @Test
    func `a vanished file marks discovered history partial instead of unavailable`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vanished = root.appendingPathComponent("vanished.jsonl")
        try Data().write(to: vanished)
        let content = try [Self.nativeMetadata, Self.nativeRequest()].joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: root.appendingPathComponent("available.jsonl"))
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        options.codexTraceDatabaseURL = root.appendingPathComponent("absent-trace.sqlite")
        var checks = 0
        let ledger = try CodexRequestLedger.load(
            startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {
                checks += 1
                // Remove an inventoried file before scanning the two-file source.
                if checks == 4 { try FileManager.default.removeItem(at: vanished) }
            })
        #expect(ledger.partial)
        #expect(try Self.price([ledger]).totalTokens == 110)
    }

    @Test
    func `scan snapshots refresh Foundation metadata after a file changes`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("a".utf8).write(to: file)
        #expect(try CodexRequestLedger.fileMetadata(file).fileSize == 1)
        _ = try file.resourceValues(forKeys: [.fileSizeKey])
        try Data("abcdefgh".utf8).write(to: file)
        #expect(try CodexRequestLedger.fileMetadata(file).fileSize == 8)
    }

    @Test(arguments: [
        "future-schema", "invalid-mode", "included-pre-cutoff",
        "provider", "window", "digest", "cached", "reasoning", "overflow", "sum",
    ])
    func `invalid source contracts and overflowing ledger totals are rejected`(invalid: String) throws {
        var source = Self.ledger()
        switch invalid {
        case "future-schema": source.schemaVersion = 3
        case "invalid-mode": source = Self.source([Self.accountingRow(mode: "flex")])
        case "included-pre-cutoff": source = Self.source([Self.accountingRow(included: true)])
        case "provider": source.provider = "claude"
        case "window": source.endUnixMs += 1
        case "digest": source.conflictingIDs = ["raw-session-id"]
        case "cached": source = Self.ledger(input: 19)
        case "reasoning": source.records = [.init(
                id: source.records[0].id,
                timestampUnixMs: Self.end,
                inputTokens: 100,
                cacheReadTokens: 20,
                outputTokens: 2,
                reasoningTokens: 3)]
        default:
            source.records = ["a", "b"].map { character in .init(
                id: String(repeating: character, count: 64),
                timestampUnixMs: Self.end,
                inputTokens: Int.max - 1,
                cacheReadTokens: 0,
                outputTokens: invalid == "overflow" ? 2 : 0,
                reasoningTokens: nil) }
        }
        let copy = try JSONDecoder().decode(CodexRequestLedger.self, from: JSONEncoder().encode(source))
        #expect(throws: RemoteCodexCostError.self) {
            try copy.validate(startUnixMs: Self.start, endUnixMs: Self.end)
        }
    }

    @Test(arguments: ["same", "contradiction", "invalid", "future-invalid", "reasoning"])
    func `native copies resumes exact UTC bounds and unidentified rows use the real parser`(variant: String)
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        options.codexTraceDatabaseURL = root.appendingPathComponent("absent-trace.sqlite")
        let metadata = #"{"type":"session_meta","payload":{"id":"fixture-session"}}"#
        let original = try metadata + "\n" + (Self.nativeRequest("copied")) + "\n"
        try Data(original.utf8).write(to: root.appendingPathComponent("original.jsonl"))
        let contradiction = ["contradiction", "invalid", "reasoning"].contains(variant)
        let resumed = try Self.nativeRequest(
            "copied",
            timestamp: "2026-08-31T12:00:00Z",
            input: variant == "contradiction" ? 101 : (variant == "invalid" ? 19 : 100),
            reasoning: variant == "reasoning" ? 4 : 3)
        let resume = try original + resumed + "\n"
            + (Self.nativeRequest("new", timestamp: "2026-08-31T00:00:00Z")) + "\n"
            + (Self.nativeRequest("exact-end", timestamp: "2026-08-31T12:00:00.003Z")) + "\n"
            + (Self.nativeRequest(
                "copied",
                timestamp: "2026-08-31T12:00:00.004Z",
                input: variant == "future-invalid" ? 19 : 102)) + "\n"
            + (Self.nativeRequest("before", timestamp: "2026-08-30T23:59:59.999Z")) + "\n"
        try Data(resume.utf8).write(to: root.appendingPathComponent("resumed.jsonl"))
        let fork = try #"{"type":"session_meta","payload":{"id":"fixture-child","forked_from_id":"fixture-session","#
            + #""timestamp":"2026-08-31T12:00:00Z"}}"#
            + "\n" + (Self.nativeRequest("copied", input: 103)) + "\n"
        try Data(fork.utf8).write(to: root.appendingPathComponent("fork.jsonl"))
        let legacy = metadata + "\n" +
            #"{"type":"event_msg","timestamp":"2026-08-31T12:00:00Z","payload":{"type":"token_count","# +
            #""info":{"model":"gpt-5","total_token_usage":{"input_tokens":100,"output_tokens":10}}}}"# +
            "\n"
        try Data(legacy.utf8).write(to: root.appendingPathComponent("legacy.jsonl"))
        let ledger = try CodexRequestLedger.load(
            startUnixMs: Self.start, endUnixMs: Self.end + 3, options: options, checkCancellation: {})
        let subtotal = try Self.price([ledger, ledger])
        #expect(subtotal.totalTokens == (contradiction ? 220 : 330))
        #expect(subtotal.requestCount == (contradiction ? 2 : 3))
        #expect(ledger.excludedCount > 0)
        let wire = try #require(String(bytes: JSONEncoder().encode(ledger), encoding: .utf8))
        #expect(!wire.contains("fixture-session"))
        #expect(!wire.contains(root.path))
    }

    @Test(arguments: ["missing", "empty", "truncated", "malformed", "oversized"])
    func `missing native histories are unavailable while damaged histories are partial`(state: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        options.codexTraceDatabaseURL = root.appendingPathComponent("absent-trace.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        if state != "missing" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if state != "empty" {
                let content = state == "oversized" ? String(repeating: "x", count: 256 * 1024 + 1) + "\n"
                    : (state == "malformed" ? "{broken}\n" : "{\"type\":\"token_usage_record\"")
                try Data(content.utf8).write(to: root.appendingPathComponent("damaged.jsonl"))
            }
        }
        if state == "missing" {
            #expect(throws: RemoteCodexCostError.self) {
                _ = try CodexRequestLedger.load(
                    startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {})
            }
        } else {
            let ledger = try CodexRequestLedger.load(
                startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {})
            #expect(ledger.records.isEmpty)
            #expect(ledger.partial == (state != "empty"))
        }
    }

    @Test
    func `SSH export pins the same window and filters the environment`() async throws {
        let ledger = Self.ledger()
        let wire = try #require(String(bytes: JSONEncoder().encode(ledger), encoding: .utf8))
        let fetcher = RemoteCodexCostFetcher { arguments, environment in
            #expect(arguments.contains("StrictHostKeyChecking=yes"))
            #expect(arguments.contains("ForwardAgent=no"))
            #expect(arguments.contains("-n"))
            #expect(arguments.last?.contains("--identified-end \(Self.end)") == true)
            #expect(arguments.last?.contains("--identified-only --days 1") == true)
            #expect(environment["UNRELATED_TOKEN"] == nil)
            return wire
        }
        let received = try await fetcher.fetchIdentifiedUsage(
            host: "fixture-host",
            historyDays: 1,
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            environment: ["UNRELATED_TOKEN": "fixture-secret"])
        #expect(received.records == ledger.records)
    }

    @Test(arguments: ["timestamp", "tokens"])
    func `accounting conflicts stay quarantined in every source order`(field: String) throws {
        let clean = Self.accountingRow()
        let changed = field == "timestamp"
            ? Self.accountingRow(timestamp: Self.end - 1) : Self.accountingRow(input: 101)
        let survivor = Self.accountingRow(id: "b")
        let a = Self.source([clean, survivor])
        let b = Self.source([changed, survivor])
        for sources in [[a, b, a], [b, a, a], [a, a, b]] {
            let result = try Self.price(sources)
            #expect(result.requestCount == 1 && result.totalTokens == 110)
            #expect(result.conflictCount == 1 && result.partial)
            #expect(result.unpricedRequestCount == 0)
        }
        let empty = try Self.price([Self.source([clean]), Self.source([changed]), Self.source([clean])])
        #expect(empty.requestCount == 0 && empty.costUSD == 0)
        #expect(empty.conflictCount == 1 && empty.partial)
        var declared = Self.source([])
        declared.conflictingIDs = [clean.id]
        #expect(try Self.price([declared, Self.source([clean])]).requestCount == 0)
    }

    @Test(arguments: ["model", "mode", "inclusion", "null-model", "null-mode"])
    func `pricing disagreements are absorbing through source orders`(field: String) throws {
        let timestamp: Int64 = 1_791_270_000_000
        let clean = Self.accountingRow(timestamp: timestamp)
        let changed = Self.accountingRow(
            model: field == "model" ? "gpt-5.4" : field == "null-model" ? nil : "gpt-5",
            mode: field == "mode" ? "priority" : field == "null-mode" ? nil : "standard",
            included: field == "inclusion",
            timestamp: timestamp)
        func source(_ rows: [CodexRequestRecord]) -> CodexRequestLedger {
            .init(startUnixMs: timestamp - 7 * 3_600_000, endUnixMs: timestamp, records: rows)
        }
        for rows in [[clean, changed, clean], [changed, clean, clean], [clean, clean, changed]] {
            let result = try Self.price(rows.map { source([$0]) } + [source([clean])])
            #expect(result.requestCount == 1 && result.totalTokens == 110)
            #expect(result.conflictCount == 0 && !result.partial)
            #expect(result.costUSD == nil && result.unpricedRequestCount == 1)
        }
    }

    @Test(arguments: ["model", "mode", "priority"])
    func `unknown prices preserve complete coverage and explicit wire nulls`(unknown: String) throws {
        let row: CodexRequestRecord = switch unknown {
        case "model": Self.accountingRow(model: nil)
        case "mode": Self.accountingRow(mode: nil)
        default: Self.accountingRow(mode: "priority") // GPT-5 has no published Fast rate.
        }
        let result = try Self.price([Self.source([row]), Self.source([row])])
        #expect(result.requestCount == 1 && result.unpricedRequestCount == 1)
        #expect(result.costUSD == nil && !result.partial)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(wire["costUSD"] is NSNull)
        #expect(wire["unpricedRequestCount"] as? Int == 1)
        let rowWire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        if unknown == "model" { #expect(rowWire["model"] is NSNull) }
        if unknown == "mode" { #expect(rowWire["pricingMode"] is NSNull) }
    }

    @Test
    func `per request thresholds apply before union pricing`() throws {
        let sources = ["a", "b", "a"].map {
            Self.source([Self.accountingRow(
                id: $0, model: "gpt-5.4", input: 200_000, cached: 100_000, output: 20, reasoning: 10)])
        }
        let result = try Self.price(sources)
        // Each 200k request stays below 272k even though their union exceeds it; reasoning is output's subset.
        #expect(try abs(#require(result.costUSD) - 0.5506) < 1e-12)
    }

    @Test
    func `historical prices use each accepted request timestamp`() throws {
        let cutoff: Int64 = 1_785_369_600_000
        let row = Self.accountingRow(
            model: "gpt-5.6-terra",
            timestamp: cutoff - 1,
            input: 1_000_000,
            cached: 0,
            output: 0,
            reasoning: nil)
        let source = CodexRequestLedger(startUnixMs: cutoff - 86_400_000, endUnixMs: cutoff, records: [row])
        let result = try Self.price([source])
        #expect(result.requestCount == 1)
        #expect(try abs(#require(result.costUSD) - 5) < 1e-12)
    }

    @Test
    func `collector catalog and custom overlay price the deduplicated union`() throws {
        let model = "gpt-5-2025-08-07"
        let ledger = Self.source([Self.accountingRow(model: model)])
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(
            (#"{"openai":{"id":"openai","models":{"gpt-5-2025-08-07":{"id":"gpt-5-2025-08-07","#
                + #""cost":{"input":2,"output":3,"cache_read":0.5}}}}}"#).utf8))
        for pricing in ["complete", "catalog"] {
            let custom = pricing == "catalog" ? CostUsageCustomPricing.empty : CostUsageCustomPricing(
                entries: [model: .init(
                    input: 4,
                    output: 5,
                    cacheRead: 1)], fingerprint: pricing)
            let result = try Self.price([ledger, ledger], catalog: catalog, custom: custom)
            #expect(result.requestCount == 1 && result.totalTokens == 110 && !result.partial)
            #expect(result.unpricedRequestCount == 0)
            let expected = pricing == "complete" ? 0.00039 : 0.0002
            #expect(try abs(#require(result.costUSD) - expected) < 1e-12)
        }
    }

    @Test(arguments: [
        "default", "priority", "synthetic-unknown", "omitted", "null", "missing", "no-record",
        "after-start-priority", "after-start-default", "after-start-ultrafast", "fresh-priority",
    ])
    func `native tiers retain standard priority and unknown evidence`(tier: String) throws {
        let settings = switch tier {
        case "omitted": Self.nativeSettings("default")
            .replacingOccurrences(of: "\"service_tier\":\"default\"", with: "\"model\":\"gpt-5\"")
        case "null": Self.nativeSettings("null").replacingOccurrences(of: "\"null\"", with: "null")
        case "missing": Self.nativeSettings("default")
            .replacingOccurrences(of: "\"thread_settings\":", with: "\"other_settings\":")
        default: Self.nativeSettings(tier)
        }
        let afterStart = tier.hasPrefix("after-start-") || tier == "fresh-priority"
        let before = afterStart
            ? (tier == "fresh-priority" ? [] : [Self.nativeSettings("default")])
            : (tier == "no-record" ? [] : [settings])
        let afterTier = tier == "fresh-priority" ? "priority" : String(tier.dropFirst("after-start-".count))
        let after = afterStart ? [Self.nativeSettings(afterTier)] : []
        let ledger = try Self.loadNative(
            [Self.nativeMetadata] + before + [Self.nativeStart("turn")] + after
                + [Self.nativeRequest(turn: "turn", model: "gpt-5.4")])
        let expectedMode: String? = ["default", "omitted", "after-start-default"].contains(tier)
            ? "standard" : ["priority", "fresh-priority"].contains(tier) ? "priority" : nil
        #expect(ledger.records.first?.pricingMode == expectedMode)
    }

    @Test
    func `inherited settings and delayed earlier turns keep their own model and tier`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeSettings("priority"), Self.nativeStart("old"),
            #"{"type":"turn_context","timestamp":"2026-08-31T11:00:00Z","#
                + #""payload":{"turn_id":"old","model":"gpt-5.4"}}"#,
            Self.nativeRequest("first", turn: "old", model: nil),
            Self.nativeSettings("default"), Self.nativeStart("new"),
            #"{"type":"turn_context","timestamp":"2026-08-31T11:01:00Z","payload":{"turn_id":"new","model":"gpt-5"}}"#,
            Self.nativeRequest("delayed", turn: "old", model: nil),
            Self.nativeRequest("new", turn: "new", model: nil),
        ])
        #expect(ledger.records.filter { $0.model == "gpt-5.4" && $0.pricingMode == "priority" }.count == 2)
        #expect(ledger.records.filter { $0.model == "gpt-5" && $0.pricingMode == "standard" }.count == 1)
    }

    @Test
    func `same turn Priority requests retain their own billing models`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeSettings("default"), Self.nativeStart("turn"),
            Self.nativeRequest("large", turn: "turn", model: "gpt-5.4"),
            Self.nativeRequest("mini", turn: "turn", model: "gpt-5.4-mini"),
        ], trace: [
            (Self.end / 1000 - 1, CodexPrioritySQLiteTests.Fixture.traceBody(model: "gpt-5.4")),
            (Self.end / 1000, CodexPrioritySQLiteTests.Fixture.traceBody(model: "gpt-5.4-mini")),
        ])
        let exported = try JSONDecoder().decode(CodexRequestLedger.self, from: JSONEncoder().encode(ledger))
        #expect(Set(exported.records.compactMap(\.model)) == ["gpt-5.4", "gpt-5.4-mini"])
        #expect(exported.records.allSatisfy { $0.pricingMode == "priority" })
    }

    @Test
    func `conflicting turn models without request evidence retain unpriced tokens`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeSettings("default"), Self.nativeStart("turn"),
            #"{"type":"turn_context","timestamp":"2026-08-31T11:01:00Z","#
                + #""payload":{"turn_id":"turn","model":"gpt-5.4"}}"#,
            Self.nativeRequest(turn: "turn", model: nil),
        ], trace: [(Self.end / 1000, CodexPrioritySQLiteTests.Fixture.traceBody(model: "gpt-5.4-mini"))])
        let subtotal = try Self.price([ledger])
        #expect(ledger.records.first?.model == nil)
        #expect(subtotal.costUSD == nil && subtotal.unpricedRequestCount == 1)
        #expect(subtotal.requestCount == 1 && subtotal.totalTokens == 110 && !subtotal.partial)
    }

    @Test(arguments: [
        "priority",
        "outside-window",
        "unmatched",
        "unsupported-model",
        "mismatched-thread",
        "unreadable",
    ])
    func `trace billing evidence is selected before price lookup`(kind: String) throws {
        let model = kind == "unsupported-model" ? "synthetic-unpriced" : "gpt-5.4"
        let thread = kind == "mismatched-thread" ? "other-thread" : "fixture-session"
        var lines = [Self.nativeMetadata]
        if kind == "unreadable" || kind == "outside-window" { lines.append(Self.nativeSettings("default")) }
        lines.append(Self.nativeStart(kind == "unmatched" ? "other-turn" : "turn"))
        try lines.append(Self.nativeRequest(turn: "turn", model: kind == "outside-window" ? "gpt-5.4" : nil))
        let ledger = try Self.loadNative(
            lines,
            trace: kind == "unreadable" ? nil : [(
                Self.start / 1000 + (kind == "outside-window" ? -2 * 24 * 3600 : kind == "priority" ? -60 : 12 * 3600),
                CodexPrioritySQLiteTests.Fixture.traceBody(thread: thread, model: model))],
            brokenTrace: kind == "unreadable")
        let row = try #require(ledger.records.first)
        let result = try Self.price([ledger])
        if kind == "priority" {
            #expect(row.pricingMode == "priority")
            #expect(try abs(#require(result.costUSD) - 0.00071) < 1e-12)
        } else if kind == "outside-window" {
            #expect(row.pricingMode == "standard")
        } else {
            #expect(result.costUSD == nil && result.unpricedRequestCount == 1)
        }
        if kind == "unsupported-model" { #expect(row.model == "synthetic-unpriced") }
        #expect(!result.partial)
    }

    @Test(arguments: ["selected", "explicit", "configured", "environment", "ambient"])
    func `identified export resolves selected and configured trace locations`(placement: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedHome = root.appendingPathComponent("selected-home", isDirectory: true)
        let sessionsRoot = selectedHome.appendingPathComponent("sessions", isDirectory: true)
        let sqliteHome = root.appendingPathComponent("sqlite-home", isDirectory: true)
        let ambientHome = root.appendingPathComponent("ambient-home", isDirectory: true)
        for directory in [sessionsRoot, sqliteHome, ambientHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if placement == "configured" {
            try Data("sqlite_home = \"\(sqliteHome.path)\"\n".utf8)
                .write(to: selectedHome.appendingPathComponent("config.toml"))
        }
        let turn = "selected-home-turn"
        let history = try [
            Self.nativeMetadata, Self.nativeSettings("default"), Self.nativeStart(turn),
            Self.nativeRequest("selected-home-request", turn: turn, model: "gpt-5.4"),
        ]
        try Data((history.joined(separator: "\n") + "\n").utf8)
            .write(to: sessionsRoot.appendingPathComponent("history.jsonl"))
        let traceHome = ["configured", "environment"].contains(placement) ? sqliteHome
            : placement == "ambient" ? ambientHome : selectedHome
        let trace = traceHome.appendingPathComponent("logs_2.sqlite")
        try CodexPrioritySQLiteTests.Fixture.createDatabase(at: trace)
        try CodexPrioritySQLiteTests.Fixture.insert(
            [(Self.start / 1000 + 12 * 60 * 60, CodexPrioritySQLiteTests.Fixture.traceBody(turn: turn))], at: trace)
        var options = CostUsageScanner.Options()
        var environment = ["CODEX_HOME": selectedHome.path, "HOME": ambientHome.path]
        if placement == "explicit" {
            let explicitTrace = root.appendingPathComponent("explicit-trace.sqlite")
            try CodexPrioritySQLiteTests.Fixture.createDatabase(at: explicitTrace)
            options.codexTraceDatabaseURL = explicitTrace
        } else if placement == "configured" || placement == "environment" {
            environment["CODEX_SQLITE_HOME"] = placement == "configured"
                ? root.appendingPathComponent("wrong-sqlite-home").path : sqliteHome.path
        } else if placement == "ambient" {
            options.codexSessionsRoot = sessionsRoot
            environment["CODEX_HOME"] = ambientHome.path
        }
        let ledger = try CodexRequestLedger.load(
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            options: options,
            environment: environment,
            processName: "CodexBar",
            checkCancellation: {})
        let exported = try JSONDecoder().decode(CodexRequestLedger.self, from: JSONEncoder().encode(ledger))
        let priority = !["explicit", "ambient"].contains(placement)
        #expect(exported.records.first?.pricingMode == (priority ? "priority" : "standard"))
        #expect(try abs(#require(Self.price([exported]).costUSD) - (priority ? 0.00071 : 0.000355)) < 1e-12)
    }

    @Test
    func `native tier disagreements absorb pricing within one file`() throws {
        let ledger = try Self.loadNative([
            Self.nativeMetadata, Self.nativeSettings("default"), Self.nativeStart("turn"),
            Self.nativeRequest(turn: "turn", model: "gpt-5.4"),
            Self.nativeSettings("priority"), Self.nativeStart("turn"),
            Self.nativeRequest(turn: "turn", model: "gpt-5.4"),
            Self.nativeRequest("survivor", turn: "turn", model: "gpt-5.4"),
        ])
        let result = try Self.price([ledger])
        #expect(result.conflictCount == 0 && !result.partial)
        #expect(result.requestCount == 2 && result.totalTokens == 220)
        #expect(result.unpricedRequestCount == 1)
    }

    @Test(arguments: [false, true])
    func `qualified auto review retains trace billing model through wire and collector override`(
        requestModel: Bool) throws
    {
        let timestamp = "2026-10-06T07:00:00Z"
        let cutoff: Int64 = 1_791_270_000_000
        let ledger = try Self.loadNative(
            [
                #"{"type":"session_meta","payload":{"id":"fixture-session","creator_account_id":"fixture-creator"}}"#,
                Self.nativeStart("turn").replacingOccurrences(of: "2026-08-31T11:00:00Z", with: timestamp),
                #"{"type":"turn_context","timestamp":""# + timestamp
                    + #"","payload":{"turn_id":"turn","model":"codex-auto-review"}}"#,
                Self.nativeRequest(turn: "turn", model: requestModel ? "codex-auto-review" : nil, timestamp: timestamp),
            ],
            trace: [(cutoff / 1000, CodexPrioritySQLiteTests.Fixture.traceBody())],
            start: cutoff - 7 * 3_600_000,
            end: cutoff)
        let copy = try JSONDecoder().decode(CodexRequestLedger.self, from: JSONEncoder().encode(ledger))
        #expect(copy.records.first?.model == "gpt-5.4")
        #expect(copy.records.first?.includedInPlan == true)
        let overlay = CostUsageCustomPricing(
            entries: ["gpt-5.4": .init(input: 4, output: 5, cacheRead: 1)], fingerprint: "fixture")
        let price = try Self.price([copy], custom: overlay)
        #expect(try abs(#require(price.costUSD) - 0.00078) < 1e-12)
    }

    @Test(arguments: [false, true])
    func `optional pricing observation leaves ordinary rows and saved settings unchanged`(
        settingsAfterStart: Bool) throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.jsonl")
        let settings = Self.nativeSettings("synthetic-unknown")
        let start = Self.nativeStart("turn")
        let lines = try [Self.nativeMetadata]
            + (settingsAfterStart ? [start, settings] : [settings, start])
            + [Self.nativeRequest(turn: "turn")]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let range = CostUsageScanner.CostUsageDayRange(
            since: Date(timeIntervalSince1970: Double(Self.start) / 1000),
            until: Date(timeIntervalSince1970: Double(Self.end) / 1000),
            calendar: calendar)
        let ordinary = try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range)
        var count = 0
        let observed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, ownedRequestObserver: { _, _, _ in
                count += 1
            })
        #expect(count == 1)
        #expect(ordinary.rows == observed.rows)
        #expect(ordinary.requestLedgerState == observed.requestLedgerState)
    }
}

extension CodexRequestSubtotalTests {
    @Test
    func `identified CLI retains repeated remote options`() throws {
        let invocation = try Program(descriptors: CodexBarCLI.commandDescriptors()).resolve(arguments: [
            "cost", "--provider", "codex", "--identified-only", "--format", "json",
            "--remote", "first", "--remote", "second",
        ])
        #expect(invocation.parsedValues.options["remote"] == ["first", "second"])
    }

    @Test(arguments: ["unavailable", "overflow"])
    func `source failures stay partial and overflow rolls back while later hosts contribute`(failure: String)
        async throws
    {
        let local = Self.ledger()
        let other = Self.ledger(id: "c")
        var rejected = Self.ledger(input: Int.max - 100, id: "b", output: 0)
        rejected.conflictingIDs = local.records.map(\.id)
        rejected.excludedCount = 5
        rejected.partial = true
        let invalid = rejected
        let stamp = Date(timeIntervalSince1970: 1234)
        let result = try await CodexBarCLI.collectIdentifiedUsage(
            remotes: ["first", "bad", "local", "last", "last"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            now: { stamp },
            local: { local },
            fetchRemote: { host in
                if host == "bad" {
                    if failure == "unavailable" { throw CocoaError(.fileReadNoPermission) }
                    return invalid
                }
                return host == "first" ? other : local
            },
            makeMerger: { { try Self.price($0) } })
        #expect(result.reports.map(\.host) == ["local", "first", "bad", "local", "last", "last"])
        #expect(result.reports.map(\.source) == ["local", "ssh", "ssh", "ssh", "ssh", "ssh"])
        #expect(result.reports.map(\.collectedAt) == [stamp, stamp, nil, stamp, stamp, stamp])
        #expect(result.reports[2].error != nil)
        #expect(result.reports[2].ledger == nil)
        #expect(result.subtotal?.totalTokens == 220)
        #expect(result.subtotal?.conflictCount == 0)
        #expect(result.subtotal?.excludedCount == 0)
        #expect(result.subtotal?.partial == false)
        #expect(!result.allSourcesAvailable && result.partial)
        let json = try #require(CodexBarCLI.encodeJSON(result, pretty: false))
        let wire = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let rows = try #require(wire["reports"] as? [[String: Any]])
        #expect(rows.map { $0["source"] as? String } == ["local", "ssh", "ssh", "ssh", "ssh", "ssh"])
        #expect(rows.enumerated().allSatisfy { index, row in (row["collectedAt"] != nil) == (index != 2) })
    }

    @Test(arguments: ["local-fails", "none", "empty", "partial"])
    func `availability is separate from an empty or partial accepted subtotal`(state: String) async throws {
        var ledger = Self.ledger()
        if state == "empty" { ledger.records = [] }
        ledger.partial = state == "partial"
        let source = ledger
        let result = try await CodexBarCLI.collectIdentifiedUsage(
            remotes: ["host"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: {
                if state == "local-fails" || state == "none" { throw RemoteCodexCostError.unavailable }
                return source
            },
            fetchRemote: { _ in
                if state == "none" { throw RemoteCodexCostError.unavailable }
                return source
            },
            makeMerger: { { try Self.price($0) } })
        #expect(result.allSourcesAvailable == (state == "empty" || state == "partial"))
        #expect(result.partial == (state != "empty"))
        #expect(result.subtotal?.totalTokens == (state == "none" ? nil : (state == "empty" ? 0 : 110)))
        if state == "none" {
            let json = try #require(CodexBarCLI.encodeJSON(result, pretty: false))
            let wire = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(wire["subtotal"] == nil)
            #expect(result.reports.allSatisfy { $0.collectedAt == nil && $0.error != nil })
        }
    }

    @Test(arguments: ["local-throws", "remote-cancels"])
    func `cancellation prevents the next SSH fetch`(cancellation: String) async {
        let task = Task {
            try await CodexBarCLI.collectIdentifiedUsage(
                remotes: ["first", "never"],
                startUnixMs: Self.start,
                endUnixMs: Self.end,
                local: {
                    if cancellation == "local-throws" { throw CancellationError() }
                    return Self.ledger()
                },
                fetchRemote: { host in
                    #expect(cancellation == "remote-cancels")
                    #expect(host == "first")
                    withUnsafeCurrentTask { $0?.cancel() }
                    return Self.ledger()
                },
                makeMerger: { { try Self.price($0) } })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

extension CodexRequestSubtotalTests {
    private static func ledger(outputBytes: Int, pretty: Bool = false) throws -> CodexRequestLedger {
        let emptyModel = self.source([self.accountingRow(model: nil, mode: nil)])
        let oneByteModel = self.source([self.accountingRow(model: "x", mode: nil)])
        let emptyWire = try #require(CodexBarCLI.encodeJSON(emptyModel, pretty: pretty))
        let oneByteWire = try #require(CodexBarCLI.encodeJSON(oneByteModel, pretty: pretty))
        let outputBytesWithoutModel = emptyWire.utf8.count + 1
        let oneByteDelta = oneByteWire.utf8.count - emptyWire.utf8.count
        let modelLength = outputBytes - outputBytesWithoutModel - oneByteDelta + 1
        let ledger = self.source([self.accountingRow(
            model: String(repeating: "x", count: modelLength), mode: nil)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        #expect(try encoder.encode(ledger).count + 1 == outputBytes)
        return ledger
    }

    private static func accountingRow(
        id: String = "a",
        model: String? = "gpt-5",
        mode: String? = "standard",
        included: Bool = false,
        timestamp: Int64? = nil,
        input: Int = 100,
        cached: Int = 20,
        output: Int = 10,
        reasoning: Int? = 3) -> CodexRequestRecord
    {
        .init(
            id: String(repeating: id, count: 64),
            timestampUnixMs: timestamp ?? self.end,
            inputTokens: input,
            cacheReadTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning,
            model: model,
            pricingMode: mode,
            includedInPlan: included)
    }

    private static func source(_ rows: [CodexRequestRecord]) -> CodexRequestLedger {
        .init(startUnixMs: self.start, endUnixMs: self.end, records: rows)
    }

    private static func price(
        _ sources: [CodexRequestLedger],
        catalog: ModelsDevCatalog = .init(providers: [:]),
        custom: CostUsageCustomPricing = .empty) throws -> CodexRequestSubtotal
    {
        try CodexRequestLedger.merge(sources, catalog: catalog, customPricing: custom)
    }

    private static func nativeRequest(
        _ response: String = "request",
        turn: String? = nil,
        model: String? = "gpt-5",
        timestamp: String = "2026-08-31T12:00:00Z",
        input: Int = 100,
        reasoning: Int = 3) throws -> String
    {
        let usage = [
            "input_tokens": input,
            "cached_input_tokens": 20,
            "output_tokens": 10,
            "reasoning_output_tokens": reasoning,
        ]
        var payload: [String: Any] = [
            "thread_id": "fixture-session",
            "response_id": response,
            "usage": usage,
            "thread_token_usage": usage,
        ]
        payload["turn_id"] = turn
        payload["model"] = model
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "token_usage_record", "timestamp": timestamp, "payload": payload,
        ], options: .sortedKeys)
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func nativeSettings(_ tier: String) -> String {
        #"{"type":"event_msg","timestamp":"2026-08-31T10:00:00Z","payload":{"type":"thread_settings_applied","#
            + #""thread_settings":{"service_tier":""#
            + tier + #""}}}"#
    }

    private static func nativeStart(_ turn: String) -> String {
        #"{"type":"event_msg","timestamp":"2026-08-31T11:00:00Z","payload":{"type":"task_started","turn_id":""#
            + turn + #""}}"#
    }

    private static func loadNative(
        _ lines: [String],
        copies: [[String]] = [],
        trace: [(Int64, String)]? = nil,
        brokenTrace: Bool = false,
        start: Int64 = Self.start,
        end: Int64 = Self.end) throws -> CodexRequestLedger
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, history) in ([lines] + copies).enumerated() {
            try Data((history.joined(separator: "\n") + "\n").utf8)
                .write(to: root.appendingPathComponent("history-\(index).jsonl"))
        }
        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = root
        options.codexTraceDatabaseURL = root.appendingPathComponent("trace.sqlite")
        if let trace {
            let database = try #require(options.codexTraceDatabaseURL)
            try CodexPrioritySQLiteTests.Fixture.createDatabase(at: database)
            try CodexPrioritySQLiteTests.Fixture.insert(trace, at: database)
        }
        if brokenTrace { try Data("not a database".utf8).write(to: #require(options.codexTraceDatabaseURL)) }
        return try CodexRequestLedger.load(
            startUnixMs: start,
            endUnixMs: end,
            options: options,
            checkCancellation: {})
    }

    private static let nativeMetadata = #"{"type":"session_meta","payload":{"id":"fixture-session"}}"#
}
