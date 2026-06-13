import Foundation
import Testing

@Suite
struct MiMoUsageScriptTests {
    @Test
    func `script keeps final cumulative streaming usage`() throws {
        try self.assertFinalStreamingUsage(includeRequestID: true)
    }

    @Test
    func `script deduplicates streaming usage without request id`() throws {
        try self.assertFinalStreamingUsage(includeRequestID: false)
    }

    private func assertFinalStreamingUsage(includeRequestID: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-usage-script-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let mimoHome = root.appendingPathComponent("mimo")
        let projects = mimoHome
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let rows = [
            self.assistantRow(timestamp: now, outputTokens: 10, includeRequestID: includeRequestID),
            self.assistantRow(timestamp: now, outputTokens: 40, includeRequestID: includeRequestID),
            self.assistantRow(timestamp: now, outputTokens: 90, includeRequestID: includeRequestID),
        ]
        let session = projects.appendingPathComponent("session.jsonl")
        let jsonl = try rows
            .map { try JSONSerialization.data(withJSONObject: $0) }
            .map { try #require(String(bytes: $0, encoding: .utf8)) }
            .joined(separator: "\n")
        try jsonl.write(to: session, atomically: true, encoding: .utf8)

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
        let allTime = try #require(windows["all_time"] as? [String: Any])
        #expect(allTime["input"] as? Int == 120)
        #expect(allTime["cache_create"] as? Int == 10)
        #expect(allTime["cache_read"] as? Int == 5)
        #expect(allTime["output"] as? Int == 90)
        #expect(allTime["messages"] as? Int == 1)
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/mimo-usage.py")
    }

    private func assistantRow(
        timestamp: String,
        outputTokens: Int,
        includeRequestID: Bool) -> [String: Any]
    {
        var row: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
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
        if includeRequestID {
            row["requestId"] = "req_stream"
        }
        return row
    }
}
