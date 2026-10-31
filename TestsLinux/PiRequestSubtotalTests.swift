import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct PiRequestSubtotalTests {
    private final class BundleMarker: NSObject {}

    @Test
    func `CLI dispatches Pi identified history and rejects invalid selectors`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #if os(macOS)
        let products = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        #else
        let products = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        #endif
        let executableURL = products.appendingPathComponent("CodexBarCLI")
        let environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "CODEX_HOME": root.path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]
        #if os(macOS)
        // Kernel-deny other processes and real-home reads so live Pi selectors cannot add personal history.
        // Linux retains core fixtures and invalid-selector coverage without an uncontained successful CLI call.
        let realHome = try URL(fileURLWithPath: String(cString: #require(getpwuid(getuid())).pointee.pw_dir))
        try Data((self.header + self.row()).utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-D", "HOME=\(realHome.resolvingSymlinksInPath().path)",
            "-D", "PRODUCTS=\(products.resolvingSymlinksInPath().path)",
            "-p", """
            (version 1)
            (allow default)
            (deny process-info*)
            (allow process-info* (target self))
            (deny file-read* (require-all (subpath (param "HOME")) (require-not (subpath (param "PRODUCTS")))))
            """,
            executableURL.path, "cost", "--provider", "pi", "--identified-only", "--format", "json",
            "--days", "1", "--identified-end", "1788177600000",
        ]
        process.environment = environment.merging(["PI_CODING_AGENT_SESSION_DIR": root.path]) { $1 }
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["provider"] as? String == "pi")
        #expect(json["schemaVersion"] as? Int == 2)
        #expect(json["startUnixMs"] as? Int64 == Self.start)
        #expect(json["endUnixMs"] as? Int64 == 1_788_177_600_000)
        #endif
        for arguments in [
            ["cost", "--identified-only", "--format", "json"],
            ["cost", "--provider", "pi", "--provider", "codex", "--identified-only", "--format", "json"],
        ] {
            let invalid = Process()
            invalid.executableURL = executableURL
            invalid.arguments = arguments
            invalid.environment = environment
            let errorOutput = Pipe()
            invalid.standardOutput = errorOutput
            invalid.standardError = FileHandle.nullDevice
            try invalid.run()
            let diagnostic = errorOutput.fileHandleForReading.readDataToEndOfFile()
            invalid.waitUntilExit()
            #expect(invalid.terminationStatus != 0)
            #expect(String(bytes: diagnostic, encoding: .utf8)?.contains("--provider codex or --provider pi") == true)
        }
    }
}

extension PiRequestSubtotalTests {
    private static let start: Int64 = 1_788_134_400_000
    private static let end: Int64 = 1_788_177_600_003

    private func scan(_ contents: [String], end: Int64 = Self.end) throws -> PiRequestLedger {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, content) in contents.enumerated() {
            let file = root.appendingPathComponent("\(index).jsonl")
            try Data(content.utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: file.path)
        }
        let cache = root.appendingPathComponent("cache")
        return try PiSessionCostScanner.loadIdentified(
            startUnixMs: Self.start,
            endUnixMs: end,
            options: .init(
                piSessionsRoot: root,
                cacheRoot: cache),
            checkCancellation: {})
    }

    private func row(
        _ id: String = "turn",
        input: String = "10",
        model: String = "gpt-5",
        backend: String = "openai",
        time: String = "2026-08-31T12:00:00Z",
        extra: String = "") -> String
    {
        """
        {"type":"message","id":"\(id)","timestamp":"\(time)","message":{"role":"assistant",\
        "provider":"\(backend)","model":"\(model)","content":"private prompt",\
        "usage":{"input":\(input),"output":0\(extra)}}}

        """
    }

    private var header: String {
        "{\"type\":\"session\",\"id\":\" session \"}\n"
    }

    @Test
    func `identified wire contains accounting only`() throws {
        let ledger = try self.scan([self.header + self.row()])
        let data = try JSONEncoder().encode(ledger)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(json["records"] as? [[String: Any]])
        let record = try #require(records.first)
        #expect(Set(record.keys) == Set([
            "id", "timestampUnixMs", "inputTokens", "outputTokens", "cacheReadTokens",
            "cacheWriteTokens", "cacheWrite1hTokens", "totalTokens",
        ]))
        #expect(ledger.records.count == 1 && ledger.records[0].totalTokens == 10)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(!text.contains("session") && !text.contains("turn") && !text.contains("private prompt"))
    }

    @Test(arguments: ["tokens", "timestamp", "rejected"])
    func `all copies participate and quarantined identities never return`(conflict: String) throws {
        let original = try self.scan([self.header + self.row()])
        let changed = self.row(
            input: conflict == "tokens" ? "11" : "10",
            time: conflict == "timestamp" ? "2026-08-31T11:00:00Z" : "2026-08-31T12:00:00Z",
            extra: conflict == "rejected" ? ",\"cacheWrite1h\":1" : "")
        let other = try self.scan([self.header + changed])
        for sources in [[original, other, original], [other, original, original], [original, original, other]] {
            let total = try PiRequestLedger.merge(sources)
            #expect(total.requestCount == 0 && total.totalTokens == 0 && total.conflictCount == 1)
        }
        let clean = self.row()
        for rows in [[clean, changed, clean], [changed, clean, clean], [clean, clean, changed]] {
            for files in [[self.header + rows.joined()], rows.map { self.header + $0 }] {
                let ledger = try self.scan(files)
                let wire = try JSONDecoder().decode(PiRequestLedger.self, from: JSONEncoder().encode(ledger))
                #expect(wire.records.isEmpty && wire.conflictingIDs.count == 1)
                #expect(wire.partial)
                #expect(try PiRequestLedger.merge([wire, original]).requestCount == 0)
            }
        }
    }

    @Test
    func `zero only records remain witnesses without counting as requests`() throws {
        let ledger = try self.scan([self.header + self.row(input: "0")])
        #expect(ledger.records.count == 1)
        let subtotal = try PiRequestLedger.merge([ledger])
        #expect(subtotal.requestCount == 0 && !subtotal.partial)
        #expect(subtotal.costUSD == nil && subtotal.unpricedRequestCount == 0)
    }

    @Test(arguments: ["model-missing", "provider-missing", "unrecognised-backend"])
    func `native metadata never affects an identified record`(metadata: String) throws {
        let row: String = switch metadata {
        case "model-missing":
            self.row().replacingOccurrences(of: "\"model\":\"gpt-5\",", with: "")
        case "provider-missing":
            self.row().replacingOccurrences(of: "\"provider\":\"openai\",", with: "")
        default:
            self.row(model: "us.anthropic.claude-sonnet-4-6-v1:0", backend: "amazon-bedrock")
        }
        let ledger = try self.scan([self.header + row])
        #expect(ledger.records.first?.totalTokens == 10)
    }

    @Test
    func `aliases disjoint caches and direct totals use scanner accounting`() throws {
        let contents = """
        {"type":"session","session_id":"session"}
        {"type":"message","id":"entry","timestamp":"2026-08-31T12:00:00Z","message":{"role":"assistant",\
        "usage":{"prompt_tokens":10,"completion_tokens":2,"cache_read_input_tokens":3,\
        "cache_creation_input_tokens":5,"cttl":{"ephemeral1h":4},"total_tokens":30}}}

        """
        let ledger = try self.scan([contents])
        let row = try #require(ledger.records.first)
        #expect(row.inputTokens == 10 && row.cacheReadTokens == 3 && row.cacheWriteTokens == 5)
        #expect(row.cacheWrite1hTokens == 4 && row.outputTokens == 2 && row.totalTokens == 30)
    }

    @Test
    func `UTC boundaries damaged rows and sessionless history are explicit`() throws {
        let contents = self.header + self.row("start", time: "2026-08-31T00:00:00Z")
            + self.row("end", time: "2026-08-31T12:00:00.003Z")
            + self.row("future", time: "2026-08-31T12:00:00.004Z")
            + self.row("before", time: "2026-08-30T23:59:59.999Z")
            + self.row("", input: "1") + self.row("bad", time: "broken")
        let ledger = try self.scan([contents])
        #expect(ledger.records.count == 2 && ledger.excludedCount == 2 && ledger.partial)
        for (contents, excluded) in [
            (self.row(extra: ",\"cacheWrite1h\":1"), 1),
            (self.row(), 1),
            (self.row(input: "0") + self.row(input: "10", time: "2026-08-31T11:00:00Z"), 1),
            (self.row(input: "10", time: "2026-08-31T11:00:00Z") + self.row(input: "0"), 1),
            (self.row(input: "10") + self.row(input: "11", time: "2026-08-31T11:00:00Z"), 1),
        ] {
            let sessionless = try self.scan([contents])
            #expect(sessionless.records.isEmpty && sessionless.conflictingIDs.isEmpty)
            #expect(sessionless.excludedCount == excluded)
            #expect(sessionless.partial)
        }
    }

    @Test
    func `Pi SSH uses fixed provider and rejects oversized output`() async throws {
        let ledger = try self.scan([self.header + self.row()])
        let wire = try #require(String(bytes: JSONEncoder().encode(ledger), encoding: .utf8))
        let fetcher = RemoteCodexCostFetcher { arguments, _ in
            #expect(arguments.last?.contains("--provider pi") == true)
            return wire
        }
        _ = try await fetcher.fetchPiIdentifiedUsage(
            host: "fixture",
            historyDays: 1,
            startUnixMs: Self.start,
            endUnixMs: Self.end)
        let padded = wire + String(
            repeating: " ",
            count: IdentifiedRequestLimits.maximumOutputBytes + 1 - wire.utf8.count)
        let oversized = RemoteCodexCostFetcher { _, _ in padded }
        await #expect(throws: RemoteCodexCostError.self) {
            _ = try await oversized.fetchPiIdentifiedUsage(
                host: "fixture", historyDays: 1, startUnixMs: Self.start, endUnixMs: Self.end)
        }
    }
}

extension PiRequestSubtotalTests {
    @Test(arguments: [
        "provider", "negative", "subset", "total", "sum", "counter",
    ])
    func `malformed wire ledgers are rejected`(kind: String) throws {
        var ledger = try self.scan([self.header + self.row()])
        switch kind {
        case "provider": ledger.provider = "codex"
        case "counter": ledger.excludedCount = -1
        default:
            let accounting = PiRequestAccounting(
                inputTokens: kind == "negative" ? -1 : (kind == "sum" ? Int.max : 10),
                outputTokens: kind == "sum" ? 1 : 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                cacheWrite1hTokens: kind == "subset" ? 1 : 0,
                totalTokens: kind == "total" ? 9 : Int.max)
            ledger.records = [.init(
                id: ledger.records[0].id,
                timestampUnixMs: Self.end,
                accounting: accounting)]
        }
        #expect(throws: RemoteCodexCostError.self) {
            try ledger.validate(startUnixMs: Self.start, endUnixMs: Self.end)
        }
    }

    @Test
    func `identities use trimmed first valid headers and separate sessions and entries`() throws {
        let first = self.header + self.row(" turn ") + self.row("b")
            + "{\"type\":\"session\",\"id\":\"ignored\"}\n" + self.row()
        let second = "{\"type\":\"session\",\"sessionId\":\"second\"}\n" + self.row()
        let ledger = try self.scan([first, second, self.row() + self.header, self.header + self.row()])
        #expect(ledger.records.count == 3 && !ledger.partial)
        #expect(ledger.records.contains {
            $0.id == "2be79e8070ccb7c02e9f3e8342eb79e4c72f1dfda6a6b200cdf35aeaae0c25f5"
        })
        #expect(try PiRequestLedger.merge([ledger]).totalTokens == 30)
        let invalidAlias = "{\"type\":\"session\",\"id\":\" \",\"sessionId\":\"not-selected\"}\n"
        let invalid = try self.scan([invalidAlias + self.row()])
        #expect(invalid.records.isEmpty && invalid.excludedCount == 1 && invalid.partial)
    }

    @Test(arguments: ["empty", "malformed", "missing", "file", "default"])
    func `available damage differs from unavailable explicit stores`(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        if kind == "file" {
            try Data().write(to: root)
        } else if kind != "missing", kind != "default" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if kind != "empty" {
                try Data("{broken}\n".utf8).write(to: root.appendingPathComponent("bad.jsonl"))
            }
        }
        let options = kind == "default" ? PiSessionCostScanner.Options(
            cacheRoot: root.appendingPathComponent("cache"),
            environment: ["HOME": root.path],
            workingDirectory: root) : PiSessionCostScanner.Options(
            piSessionsRoot: root,
            cacheRoot: root.appendingPathComponent("cache"))
        if ["missing", "file"].contains(kind) {
            #expect(throws: RemoteCodexCostError.self) {
                _ = try PiSessionCostScanner.loadIdentified(
                    startUnixMs: Self.start,
                    endUnixMs: Self.end,
                    options: options,
                    checkCancellation: {})
            }
        } else {
            let ledger = try PiSessionCostScanner.loadIdentified(
                startUnixMs: Self.start,
                endUnixMs: Self.end,
                options: options,
                checkCancellation: {})
            #expect(ledger.records.isEmpty && ledger.partial == (kind == "malformed"))
            if kind == "default" { #expect(!FileManager.default.fileExists(atPath: root.path)) }
        }
    }

    @Test
    func `distinct observations exceeding the bound before a header reject the source`() throws {
        var lines = ""
        for index in 0...IdentifiedRequestLimits.maximumRecords {
            lines += self.row("entry-\(index)")
        }
        #expect(throws: RemoteCodexCostError.self) { _ = try self.scan([lines]) }
    }

    @Test
    func `replaced files retain available rows and mark coverage partial`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("changing.jsonl")
        try Data((self.header + self.row()).utf8).write(to: file)
        let changed = self.header + self.row() + self.row("second")
        let replace: @Sendable () -> Void = {
            try? Data(changed.utf8).write(to: file, options: .atomic)
        }
        let ledger = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(replace) {
            try PiSessionCostScanner.loadIdentified(
                startUnixMs: Self.start,
                endUnixMs: Self.end,
                options: .init(piSessionsRoot: root, cacheRoot: root.appendingPathComponent("cache")),
                checkCancellation: {})
        }
        #expect(ledger.records.count == 2 && ledger.partial)
    }
}

extension PiRequestSubtotalTests {
    @Test
    func `record limit fits actual compact and pretty stdout`() throws {
        var ledger = PiRequestLedger(startUnixMs: Self.start, endUnixMs: Self.end)
        ledger.records = (0..<IdentifiedRequestLimits.maximumRecords).map { index in
            let suffix = String(index, radix: 16)
            return PiRequestRecord(
                id: String(repeating: "0", count: 64 - suffix.count) + suffix,
                timestampUnixMs: Self.end,
                accounting: .init(
                    inputTokens: 1,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    cacheWrite1hTokens: 0,
                    totalTokens: 1))
        }
        try ledger.validate(startUnixMs: Self.start, endUnixMs: Self.end)
        for pretty in [false, true] {
            let output = try #require(CodexBarCLI.encodeJSON(ledger, pretty: pretty))
            #expect(output.utf8.count + 1 <= IdentifiedRequestLimits.maximumOutputBytes)
        }
    }

    @Test
    func `live process selected history participates`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data((self.header + self.row()).utf8).write(to: sessions.appendingPathComponent("session.jsonl"))
        let ledger = try PiSessionCostScanner.loadIdentified(
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            options: .init(
                cacheRoot: root.appendingPathComponent("cache"),
                environment: ["HOME": root.path],
                workingDirectory: root,
                processContexts: [.init(
                    command: "pi --session-dir \(sessions.path)",
                    workingDirectory: root,
                    selectorEnvironment: ["HOME": root.path])]),
            checkCancellation: {})
        #expect(ledger.records.count == 1 && !ledger.partial)
    }
}

extension PiRequestSubtotalTests {
    @Test
    func `Pi and OMP roots share an identity namespace`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pi = root.appendingPathComponent("pi")
        let omp = root.appendingPathComponent("omp")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [pi, omp] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((self.header + self.row()).utf8).write(to: directory.appendingPathComponent("copy.jsonl"))
        }
        try Data((self.header + self.row("second")).utf8).write(to: omp.appendingPathComponent("other.jsonl"))
        let ledger = try PiSessionCostScanner.loadIdentified(
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            options: .init(piSessionsRoot: pi, ompSessionsRoot: omp, cacheRoot: root.appendingPathComponent("cache")),
            checkCancellation: {})
        let subtotal = try PiRequestLedger.merge([ledger])
        #expect(subtotal.totalTokens == 20 && subtotal.requestCount == 2 && !subtotal.partial)
    }
}

extension PiRequestSubtotalTests {
    @Test
    func `shared collector uses Pi reduction and retains later hosts after overflow`() async throws {
        let local = try self.scan([self.header + self.row()])
        let later = try self.scan([self.header + self.row("distinct", input: "13")])
        var rejected = later
        rejected.records = [.init(
            id: later.records[0].id,
            timestampUnixMs: Self.end,
            accounting: .init(
                inputTokens: Int.max,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                cacheWrite1hTokens: 0,
                totalTokens: Int.max))]
        let bad = rejected
        let result = try await CodexBarCLI.collectIdentifiedUsage(
            remotes: ["copy", "bad", "local", "copy"],
            startUnixMs: Self.start,
            endUnixMs: Self.end,
            local: { local },
            fetchRemote: { host in
                if host == "bad" {
                    return bad
                }
                return host == "local" ? later : local
            })
        let subtotal = try #require(result.subtotal)
        #expect(subtotal.requestCount == 2 && subtotal.totalTokens == 23)
        #expect(subtotal.costUSD == nil && subtotal.unpricedRequestCount == 2)
    }
}

extension PiRequestSubtotalTests {
    @Test(arguments: [false, true])
    func `valid sources can exceed the source cardinality limit in union`(conflicted: Bool) throws {
        func source(_ values: Range<Int>) -> PiRequestLedger {
            var ledger = PiRequestLedger(startUnixMs: Self.start, endUnixMs: Self.end)
            ledger.partial = conflicted
            for value in values {
                let id = String(format: "%064x", value)
                if conflicted {
                    ledger.conflictingIDs.append(id)
                } else {
                    ledger.records.append(.init(
                        id: id,
                        timestampUnixMs: Self.end,
                        accounting: .init(
                            inputTokens: 1,
                            outputTokens: 0,
                            cacheReadTokens: 0,
                            cacheWriteTokens: 0,
                            cacheWrite1hTokens: 0,
                            totalTokens: 1)))
                }
            }
            return ledger
        }
        let local = source(0..<25000)
        let remote = source(25000..<50001)
        try local.validate(startUnixMs: Self.start, endUnixMs: Self.end)
        try remote.validate(startUnixMs: Self.start, endUnixMs: Self.end)
        let subtotal = try PiRequestLedger.merge([local, remote])
        #expect(subtotal.requestCount == (conflicted ? 0 : 50001))
        #expect(subtotal.conflictCount == (conflicted ? 50001 : 0))
        #expect(subtotal.totalTokens == (conflicted ? 0 : 50001))
    }
}
