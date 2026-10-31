import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct ClaudeRequestSubtotalTests {
    static let start: Int64 = 1_788_134_400_000
    static let end: Int64 = 1_788_177_600_000

    static func line(
        output: String = "5",
        input: String = "191",
        stop: String = #","stop_reason":"end_turn""#,
        cache: String = #","cache_read_input_tokens":1664"#,
        model: String = #","model":"claude-sonnet-4-5""#,
        identity: String = #""sessionId":"session","requestId":"request","#) -> String
    {
        """
        {"type":"assistant",\(identity)"timestamp":"2026-08-31T12:00:00Z","message":{\
        "id":"message"\(model)\(stop),"usage":{"input_tokens":\(input),"output_tokens":\(output)\(cache)}}}
        """
    }

    static func load(
        _ lines: [String], direct: Bool = false, terminated: Bool = true) throws
        -> ClaudeRequestLedger
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audit.jsonl")
        try Data((lines.joined(separator: "\n") + (terminated ? "\n" : "")).utf8).write(to: file)
        var options = CostUsageScanner.Options()
        options.claudeProjectsRoots = [direct ? file : root]
        return try ClaudeRequestLedger.load(
            startUnixMs: self.start, endUnixMs: self.end, options: options, checkCancellation: {})
    }

    static func subtotal(_ ledgers: [ClaudeRequestLedger]) throws -> CodexRequestSubtotal {
        try ClaudeRequestLedger.merge(
            ledgers, resolver: CostUsagePricing.ClaudeResolver(catalog: ModelsDevCatalog(providers: [:])))
    }

    @Test(arguments: [false, true])
    func `every unpriced accepted Claude request is counted`(knownFirst: Bool) throws {
        let known = "claude-sonnet-4-5"
        let models: [String?] = knownFirst ? [known, nil, "claude-test-unknown"] : [nil, "claude-test-unknown", known]
        var ledger = ClaudeRequestLedger(startUnixMs: Self.start, endUnixMs: Self.end)
        ledger.records = models.enumerated().map { index, model in
            ClaudeRequestRecord(
                id: String(repeating: String(index), count: 64),
                timestampUnixMs: Self.start,
                model: model,
                missingModel: model == nil,
                inputTokens: 1,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                cacheCreationOneHourTokens: 0,
                outputTokens: 1,
                accountingState: .terminal)
        }
        let subtotal = try Self.subtotal([ledger])
        #expect(subtotal.requestCount == 3)
        #expect(subtotal.totalTokens == 6)
        #expect(subtotal.costUSD == nil)
        #expect(subtotal.unpricedRequestCount == 2)
    }

    @Test(arguments: [false, true])
    func `Claude collector failures identify the provider schema and recovery`(localFails: Bool) async throws {
        let ledger = try Self.load([Self.line()])
        let result = try await CodexBarCLI.collectIdentifiedUsage(
            remotes: ["fixture-host"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: {
                if localFails { throw RemoteCodexCostError.unavailable }
                return ledger
            },
            fetchRemote: { _ in
                if !localFails { throw RemoteCodexCostError.unavailable }
                return ledger
            }, makeMerger: { { try Self.subtotal($0) } })
        let error = try #require(result.reports[localFails ? 0 : 1].error)
        #expect(error.contains("Claude"))
        #expect(error.contains("try fewer --days"))
        #expect(error.contains("50,000 records and 32 MiB"))
        if !localFails {
            #expect(error.contains("schema 1 --identified-only"))
            #expect(error.contains("Check SSH and update its CLI"))
        }
    }

    @Test
    func `native Claude exports private accounting`() throws {
        let ledger = try Self.load([Self.line()], direct: true)
        let json = try #require(String(data: JSONEncoder().encode(ledger), encoding: .utf8))
        for secret in ["session", "request", "message", "audit.jsonl", "end_turn"] {
            #expect(!json.contains(secret))
        }
        #expect(ledger.provider == "claude")
        #expect(!ledger.partial)
    }

    @Test
    func `zero usage placeholders do not change priced request totals`() throws {
        let placeholder = Self.line(
            output: "0",
            input: "0",
            cache: "",
            model: #","model":"<synthetic>""#,
            identity: #""requestId":"placeholder","#)
        let ledger = try Self.load([placeholder, Self.line()])
        let result = try Self.subtotal([ledger])
        #expect(result.requestCount == 1)
        #expect(result.totalTokens == 1860)
        #expect(result.costUSD != nil)
        #expect(result.excludedCount == 0)
        #expect(!ledger.partial)

        for (stop, conflict) in [(#","stop_reason":"end_turn""#, true), ("", true), (#","stop_reason":null"#, false)] {
            let zero = Self.line(output: "0", input: "0", stop: stop, cache: "")
            let clean = Self.line()
            for lines in [[zero, clean, clean], [clean, zero, clean]] {
                let partitions = try [Self.load([lines[0]]), Self.load(Array(lines.dropFirst()))].map {
                    try JSONDecoder().decode(ClaudeRequestLedger.self, from: JSONEncoder().encode($0))
                }
                for sources in try [[Self.load(lines)], partitions] {
                    let result = try Self.subtotal(sources)
                    #expect(result.requestCount == (conflict ? 0 : 1))
                    #expect(result.conflictCount == (conflict ? 1 : 0))
                    #expect(result.partial == conflict)
                }
            }
        }
    }

    @Test
    func `nullable zero cache detail preserves authoritative usage`() throws {
        let ledger = try Self.load([Self.line(
            cache: #","cache_read_input_tokens":1664,"cache_creation_input_tokens":0,"cache_creation":null"#)])
        let result = try Self.subtotal([ledger])
        #expect(result.requestCount == 1)
        #expect(result.totalTokens == 1860)
        #expect(result.conflictCount == 0)
        #expect(result.excludedCount == 0)
        #expect(!result.partial)
    }

    @Test(arguments: [
        ("4", "snapshot", "855", "terminal", false),
        ("855", "terminal", "900", "snapshot", true),
        ("855", "terminal", "4", "terminal", true),
        ("855", "terminal", "855", "terminal", false),
    ])
    func `stream evidence is invariant across order and serialized source partitions`(
        first: String,
        firstState: String,
        second: String,
        secondState: String,
        conflict: Bool) throws
    {
        func stop(_ state: String) -> String {
            state == "snapshot" ? #","stop_reason":null"# : #","stop_reason":"end_turn""#
        }
        let a = Self.line(output: first, stop: stop(firstState))
            .replacingOccurrences(of: "12:00:00Z", with: "11:59:59.800Z")
        let b = Self.line(output: second, stop: stop(secondState))
            .replacingOccurrences(of: "12:00:00Z", with: "11:59:59.900Z")
        let clean = Self.line(output: "855")
        for lines in [[a, b, clean], [b, a, clean], [clean, a, b], [clean, b, a], [a, clean, b], [b, clean, a]] {
            let together = try Self.load(lines)
            let partitions = try [Array(lines.prefix(2)), [lines[2]]].map {
                try JSONDecoder().decode(ClaudeRequestLedger.self, from: JSONEncoder().encode(Self.load($0)))
            }
            for ledgers in [[together], partitions, Array(partitions.reversed())] {
                let result = try Self.subtotal(ledgers)
                #expect(result.conflictCount == (conflict ? 1 : 0))
                #expect(result.requestCount == (conflict ? 0 : 1))
                #expect(result.totalTokens == (conflict ? 0 : 2710))
                if !conflict {
                    // The subtotal has no timestamp field; inspect the same reducer used by merge.
                    var reducer = ClaudeRequestLedger.Reducer()
                    for ledger in ledgers {
                        for row in ledger.records {
                            reducer.add(row)
                        }
                    }
                    #expect(try #require(reducer.records.values.first).timestampUnixMs == Self.end - 200)
                }
            }
        }
    }

    @Test
    func `proxy estimates recover across hosts but never clear hard rejection`() throws {
        let pending = try Self.load([Self.line(output: "0", input: "1612", stop: #","stop_reason":null"#, cache: "")])
        let complete = try Self.load([Self.line()])
        let bad = try Self.load([Self.line(input: "-1")])
        #expect(try Self.subtotal([pending]).excludedCount == 1)
        for sources in [[pending, complete], [complete, pending]] {
            let result = try Self.subtotal(sources)
            #expect(result.totalTokens == 1860)
            #expect(result.excludedCount == 0)
            #expect(pending.partial)
            #expect(try Self.subtotal(sources + [bad, complete]).conflictCount == 1)
        }
    }

    static var invalidUsageLines: [String] {
        [
            line(
                cache: #","cache_creation_input_tokens":20,"cache_creation":{"ephemeral_1h_input_tokens":10,"#
                    + #""ephemeral_5m_input_tokens":5}"#),
            line(cache: #","cache_creation_input_tokens":1,"cache_creation":null"#),
            line(cache: #","cache_creation_input_tokens":null,"cache_creation":null"#),
            line(cache: #","cache_creation_input_tokens":0,"cache_creation":false"#),
            line(cache: #","cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":null}"#),
            line(input: "null"),
            line(input: "1e400"),
            line(input: "9223372036854775807"),
            line(output: "0", input: "0", cache: #","cache_read_input_tokens":null"#),
            line(output: "0", input: "0", cache: #","cache_creation":false"#),
            line(output: "0", input: "0", stop: #","stop_reason":false"#, cache: ""),
            line(output: "0", stop: #","stop_reason":null"#, cache: #","cache_creation":false"#),
            line(
                output: "0",
                stop: #","stop_reason":null"#,
                cache: #","cache_creation":{"ephemeral_5m_input_tokens":1}"#),
            line(
                output: "0",
                stop: #","stop_reason":null"#,
                cache: #","cache_creation":{"ephemeral_1h_input_tokens":-1}"#),
            line(input: #"191,"input_tokens":192"#),
            line(identity: #""metadata":{"sessionId":"first","sessionId":"second"},"#),
            line(identity: "").replacingOccurrences(
                of: #""id":"message""#,
                with: #""metadata":{"sessionId":"first","sessionId":"second"},"id":"message""#),
        ] + ["10", "4611686018427387904"].map { tokens in
            Self.line(cache: #","cache_creation_input_tokens":"# + tokens
                + #","cache_creation":{"ephemeral_1h_input_tokens":"# + tokens
                + #","ephemeral_5m_input_tokens":"# + tokens + "}")
        }
    }

    @Test(arguments: Self.invalidUsageLines)
    func `invalid supplied usage quarantines known identity`(raw: String) throws {
        let bad = try Self.load([raw])
        #expect(bad.records.isEmpty)
        #expect(bad.conflictingIDs.count == 1)
        #expect(bad.partial)
        let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        let metadata = object?["metadata"] as? [String: Any]
            ?? ((object?["message"] as? [String: Any])?["metadata"] as? [String: Any])
        let identity = (metadata?["sessionId"] as? String).map { #""sessionId":"\#($0)","# }
        let good = try Self.load([identity.map { Self.line(identity: $0) } ?? Self.line()])
        let result = try Self.subtotal([bad, good])
        #expect(result.requestCount == 0)
        #expect(result.conflictCount == 1)
    }

    @Test
    func `missing model remains unpriced and contradictory known models remain conflicts`() throws {
        let missing = try Self.load([Self.line(model: "")])
        let a = try Self.load([Self.line()])
        let b = try Self.load([Self.line(model: #","model":"claude-opus-4-5""#)])
        for sources in [[a, missing], [missing, a]] {
            let result = try Self.subtotal(sources)
            #expect(result.requestCount == 1)
            #expect(result.costUSD == nil)
            #expect(try Self.subtotal(sources + [b]).conflictCount == 1)
        }
    }

    @Test
    func `request identity crosses sessions and session fallback preserves exact nonblank bytes`() throws {
        let a = try Self.load([Self.line()])
        let other = try Self.load([Self.line(identity: #""sessionId":"other","request_id":"request","#)])
        #expect(try Self.subtotal([a, other]).requestCount == 1)
        let fallback = try Self.load([Self.line(identity: #""session_id":"session","#)])
        let spaced = try Self.load([Self.line(identity: #""sessionId":" session","#)])
        #expect(try Self.subtotal([fallback, spaced, a]).requestCount == 3)
        let blank = try Self.load([Self.line(identity: #""sessionId":" ","#)])
        #expect(blank.records.isEmpty)
        #expect(blank.excludedCount == 1)
    }

    @Test
    func `exact UTC boundaries damaged lines and missing roots remain explicit`() throws {
        let valid = Self.line()
        let ledger = try Self.load([
            valid.replacingOccurrences(of: "12:00:00Z", with: "12:00:00.001Z"),
            valid.replacingOccurrences(of: "12:00:00Z", with: "00:00:00Z"),
            "{broken", #"{"type":"assistant","#,
        ])
        #expect(try Self.subtotal([ledger]).requestCount == 1)
        #expect(ledger.partial)
        #expect(try Self.load([]).records.isEmpty)
        var options = CostUsageScanner.Options()
        options.claudeProjectsRoots = [URL(fileURLWithPath: "/nonexistent-claude-fixture")]
        #expect {
            try ClaudeRequestLedger.load(
                startUnixMs: Self.start,
                endUnixMs: Self.end,
                options: options,
                checkCancellation: {})
        } throws: { error in
            guard case RemoteCodexCostError.unavailable = error else { return false }
            return true
        }
    }

    @Test
    func `SSH forwards Claude and decodes its ledger`() async throws {
        let local = try Self.load([Self.line()])
        let wire = try #require(String(data: JSONEncoder().encode(local), encoding: .utf8))
        let fetcher = RemoteCodexCostFetcher(runner: { args, _ in
            #expect(args.last?.contains("--provider claude") == true)
            return wire
        })
        let received: ClaudeRequestLedger = try await fetcher.fetchIdentifiedUsage(
            host: "fixture-host",
            historyDays: 1,
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            ledgerType: ClaudeRequestLedger.self)
        #expect(received.records == local.records)
    }

    @Test
    func `wire schema state window digest and limits are validated`() throws {
        let good = try Self.load([Self.line()])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
        for (key, value) in [("provider", "codex" as Any), ("schemaVersion", 2), ("startUnixMs", Self.start + 1)] {
            var bad = json
            bad[key] = value
            let ledger = try JSONDecoder().decode(
                ClaudeRequestLedger.self,
                from: JSONSerialization.data(withJSONObject: bad))
            #expect { try Self.subtotal([ledger]) } throws: { error in
                guard case RemoteCodexCostError.invalidReport = error else { return false }
                return true
            }
        }
        var rows = try #require(json["records"] as? [[String: Any]])
        rows[0].removeValue(forKey: "accountingState")
        json["records"] = rows
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ClaudeRequestLedger.self, from: JSONSerialization.data(withJSONObject: json))
        }
        var bad = good
        bad.conflictingIDs = ["not-a-digest"]
        #expect { try Self.subtotal([bad]) } throws: { error in
            guard case RemoteCodexCostError.invalidReport = error else { return false }
            return true
        }
        bad = good
        bad.records = Array(repeating: good.records[0], count: CodexRequestLedger.maximumRecords + 1)
        #expect { try Self.subtotal([bad]) } throws: { error in
            guard case RemoteCodexCostError.invalidReport = error else { return false }
            return true
        }
    }

    @Test
    func `collector pricing uses all cache buckets and the historical timestamp`() throws {
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(#"""
        {"anthropic":{"models":{"claude-test-ledger":{"id":"claude-test-ledger",
        "cost":{"input":2,"output":4,"cache_read":0.5,"cache_write":3}}}}}
        """#.utf8))
        let resolver = CostUsagePricing.ClaudeResolver(catalog: catalog)
        let cache = #","cache_read_input_tokens":50,"cache_creation_input_tokens":20,"#
            + #""cache_creation":{"ephemeral_1h_input_tokens":10}"#
        let ledger = try Self.load([Self.line(
            output: "5",
            input: "100",
            cache: cache,
            model: #","model":"claude-test-ledger""#)])
        let equalBuckets = try Self.load([Self.line(
            output: "5",
            input: "100",
            cache: cache.replacingOccurrences(of: "10}", with: #"10,"ephemeral_5m_input_tokens":10}"#),
            model: #","model":"claude-test-ledger""#)])
        let result = try ClaudeRequestLedger.merge([ledger, equalBuckets], resolver: resolver)
        // $2/M input, $0.5/M reads, $3/M writes, and 2x input rate for the one-hour subset.
        #expect(result.totalTokens == 175)
        #expect(try abs(#require(result.costUSD) - 0.000315) < 1e-12)

        var historical = try Self.load([Self.line(
            output: "1",
            input: "200001",
            cache: "",
            model: #","model":"claude-sonnet-4-6""#)])
        let beforeCutoff: Int64 = 1_773_359_999_999
        historical.startUnixMs = beforeCutoff / 86_400_000 * 86_400_000
        historical.endUnixMs = beforeCutoff
        historical.records[0].timestampUnixMs = beforeCutoff
        let old = try ClaudeRequestLedger.merge([historical], resolver: resolver)
        #expect(try abs(#require(old.costUSD) - 1.2000285) < 1e-12)
    }

    @Test
    func `retained model bytes reject an oversized source`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.jsonl")
        let model = String(repeating: "x", count: 500_000)
        let rows = (0..<70).map { index in
            Self.line(
                model: ",\"model\":\"\(model)\"",
                identity: "\"requestId\":\"request-\(index)\",")
        }
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: file)
        var options = CostUsageScanner.Options()
        options.claudeProjectsRoots = [root]
        #expect(throws: RemoteCodexCostError.self) {
            try ClaudeRequestLedger.load(
                startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {})
        }
    }

    @Test
    func `exact integer accounting preserves the lexeme beyond Foundation precision`() throws {
        let ledger = try Self.load([Self.line(output: "0", input: "9007199254740993.0", cache: "")])
        #expect(try #require(ledger.records.first).inputTokens == 9_007_199_254_740_993)
        #expect(try Self.subtotal([ledger]).totalTokens == 9_007_199_254_740_993)
    }

    @Test
    func `changed source content is partial and scan cancellation escapes`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("changing.jsonl")
        let data = Data((Self.line() + "\n").utf8)
        try data.write(to: file)
        var options = CostUsageScanner.Options()
        options.claudeProjectsRoots = [root]
        let replacement = Data((Self.line(input: "192") + "\n").utf8)
        #expect(replacement.count == data.count)
        let observer: @Sendable (CostUsageScanner.ClaudeScanWork) -> Void = { work in
            if case .claudeLineDecode = work {
                #expect(throws: Never.self) { try replacement.write(to: file, options: .atomic) }
            }
        }
        let ledger = try CostUsageScanner.$observeClaudeScanWorkForTesting.withValue(observer) {
            try ClaudeRequestLedger.load(
                startUnixMs: Self.start, endUnixMs: Self.end, options: options, checkCancellation: {})
        }
        #expect(try Data(contentsOf: file) == replacement)
        #expect(ledger.records.first?.inputTokens == 191)
        #expect(ledger.partial)
        var cancellationChecks = 0
        #expect(throws: CancellationError.self) {
            try ClaudeRequestLedger.load(
                startUnixMs: Self.start,
                endUnixMs: Self.end,
                options: options,
                checkCancellation: {
                    cancellationChecks += 1
                    if cancellationChecks == 6 { throw CancellationError() }
                })
        }
    }

    @Test
    func `foreign provider rows do not become native exclusions`() throws {
        let vertex = Self.line(model: #","model":"claude-sonnet-4-5@20250929""#)
        let ledger = try Self.load([vertex])
        #expect(ledger.records.isEmpty)
        #expect(ledger.excludedCount == 0)
        #expect(!ledger.partial)
    }

    @Test
    func `overflowing Claude merged totals are rejected`() throws {
        let local = try Self.load([Self.line()])
        let large = Self.line(
            input: String(Int.max / 2), identity: #""requestId":"remote-request","#)
        let remote = try Self.load([large, large.replacingOccurrences(
            of: #""requestId":"remote-request""#,
            with: #""requestId":"other""#)])
        #expect(throws: RemoteCodexCostError.self) {
            try Self.subtotal([local, remote])
        }
    }

    @Test
    func `overflowing numeric evidence at EOF still quarantines the identity`() throws {
        let bad = try Self.load([Self.line(input: "1e400")], terminated: false)
        let good = try Self.load([Self.line()])
        #expect(try Self.subtotal([bad, good]).conflictCount == 1)
        #expect(try Self.subtotal([bad, good]).requestCount == 0)
    }
}
