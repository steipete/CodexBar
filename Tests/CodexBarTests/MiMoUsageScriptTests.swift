import Foundation
import Testing

struct MiMoUsageScriptTests {
    @Test
    func `script keeps final cumulative streaming usage`() throws {
        let rows = [
            self.assistantRow(outputTokens: 10),
            self.assistantRow(outputTokens: 40),
            self.assistantRow(outputTokens: 90),
        ]
        let allTime = try self.runScript(files: ["session.jsonl": rows])

        self.assertUsage(
            allTime,
            expected: .init(input: 120, cacheCreate: 10, cacheRead: 5, output: 90, messages: 1))
    }

    @Test
    func `script keeps final cumulative streaming usage without session id`() throws {
        let rows = [
            self.assistantRow(outputTokens: 10, sessionID: nil),
            self.assistantRow(outputTokens: 40, sessionID: nil),
            self.assistantRow(outputTokens: 90, sessionID: nil),
        ]
        let allTime = try self.runScript(files: ["session.jsonl": rows])

        self.assertUsage(
            allTime,
            expected: .init(input: 120, cacheCreate: 10, cacheRead: 5, output: 90, messages: 1))
    }

    @Test
    func `script keeps final cumulative usage without request id`() throws {
        let rows = [
            self.assistantRow(outputTokens: 10, requestID: nil),
            self.assistantRow(outputTokens: 40, requestID: nil),
            self.assistantRow(outputTokens: 90, requestID: nil),
        ]
        let allTime = try self.runScript(files: ["session.jsonl": rows])

        self.assertUsage(
            allTime,
            expected: .init(input: 120, cacheCreate: 10, cacheRead: 5, output: 90, messages: 1))
    }

    @Test
    func `script counts rows without session identity conservatively`() throws {
        let rows = [
            self.assistantRow(outputTokens: 10, sessionID: nil, requestID: nil),
            self.assistantRow(outputTokens: 40, sessionID: nil, requestID: nil),
            self.assistantRow(outputTokens: 90, sessionID: nil, requestID: nil),
        ]
        let allTime = try self.runScript(files: ["session.jsonl": rows])

        self.assertUsage(
            allTime,
            expected: .init(input: 360, cacheCreate: 30, cacheRead: 15, output: 140, messages: 3))
    }

    @Test
    func `script keeps distinct requests sharing a message id`() throws {
        let rows = [
            self.assistantRow(outputTokens: 40, requestID: "req_one"),
            self.assistantRow(outputTokens: 90, requestID: "req_two"),
        ]
        let allTime = try self.runScript(files: ["session.jsonl": rows])

        self.assertUsage(
            allTime,
            expected: .init(input: 240, cacheCreate: 20, cacheRead: 10, output: 130, messages: 2))
    }

    @Test
    func `script deduplicates copied rows from the same session`() throws {
        let rows = [self.assistantRow(outputTokens: 90)]
        let allTime = try self.runScript(files: [
            "session.jsonl": rows,
            "session-copy.jsonl": rows,
        ])

        self.assertUsage(
            allTime,
            expected: .init(input: 120, cacheCreate: 10, cacheRead: 5, output: 90, messages: 1))
    }

    @Test
    func `script deduplicates copied requests from different sessions`() throws {
        let allTime = try self.runScript(files: [
            "session-a.jsonl": [self.assistantRow(outputTokens: 90, sessionID: "session_a")],
            "session-b.jsonl": [self.assistantRow(outputTokens: 90, sessionID: "session_b")],
        ])

        self.assertUsage(
            allTime,
            expected: .init(input: 120, cacheCreate: 10, cacheRead: 5, output: 90, messages: 1))
    }

    private func runScript(files: [String: [[String: Any]]]) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-usage-script-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let mimoHome = root.appendingPathComponent("mimo")
        let projects = mimoHome
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        for (name, rows) in files {
            let session = projects.appendingPathComponent(name)
            let jsonl = try rows
                .map { try JSONSerialization.data(withJSONObject: $0) }
                .map { try #require(String(bytes: $0, encoding: .utf8)) }
                .joined(separator: "\n")
            try jsonl.write(to: session, atomically: true, encoding: .utf8)
        }

        let cache = root.appendingPathComponent("usage.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", self.scriptURL.path, "--update"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MIMO_CLAUDE_HOME": mimoHome.path,
            "MIMO_LOCAL_USAGE_PATH": cache.path,
        ]) { _, new in new }
        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let errorText = try #require(String(
            bytes: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8))
        #expect(process.terminationStatus == 0, Comment(rawValue: errorText))

        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        let windows = try #require(payload["windows"] as? [String: Any])
        return try #require(windows["all_time"] as? [String: Any])
    }

    private func assertUsage(_ allTime: [String: Any], expected: UsageExpectation) {
        #expect(allTime["input"] as? Int == expected.input)
        #expect(allTime["cache_create"] as? Int == expected.cacheCreate)
        #expect(allTime["cache_read"] as? Int == expected.cacheRead)
        #expect(allTime["output"] as? Int == expected.output)
        #expect(allTime["messages"] as? Int == expected.messages)
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/mimo-usage.py")
    }

    private func assistantRow(
        outputTokens: Int,
        sessionID: String? = "session_stream",
        requestID: String? = "req_stream") -> [String: Any]
    {
        var row: [String: Any] = [
            "type": "assistant",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": [
                "id": "msg_stream",
                "usage": [
                    "input_tokens": 120,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": outputTokens,
                ],
            ],
        ]
        if let sessionID {
            row["sessionId"] = sessionID
        }
        if let requestID {
            row["requestId"] = requestID
        }
        return row
    }

    private struct UsageExpectation {
        let input: Int
        let cacheCreate: Int
        let cacheRead: Int
        let output: Int
        let messages: Int
    }
}
