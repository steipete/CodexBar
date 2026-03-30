import Foundation
import Testing
@testable import CodexBarCore

struct CodexSessionAnalyticsLoaderTests {
    @Test
    func `loader aggregates recent codex rollout analytics`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let baseDay = try env.makeLocalNoon(year: 2026, month: 3, day: 1)

        for index in 0..<21 {
            let start = baseDay.addingTimeInterval(TimeInterval(index * 3600))
            let contents = try self.sessionJSONL(
                id: "session-\(index)",
                startedAt: start,
                userMessage: "Session \(index)\nDo work",
                items: [
                    .functionCall(
                        name: "exec_command",
                        arguments: ["cmd": index.isMultiple(of: 2) ? "swift test" : "rg Session"]),
                    .functionCallOutput(output: "Command: exec\nWall time: 6.2 seconds\nProcess exited with code 0"),
                    .functionCall(
                        name: index.isMultiple(of: 3) ? "write_stdin" : "mcp__vercel__get_project",
                        arguments: ["chars": "npm test\n"]),
                    .functionCallOutput(output: index
                        .isMultiple(of: 4) ? "tool call error: handshake failed" :
                        "Command: second\nWall time: 120ms\nProcess exited with code 0"),
                ],
                includeMalformedLine: index == 5)
            _ = try env.writeCodexSessionFile(
                day: start,
                filename: "rollout-2026-03-\(String(format: "%02d", index + 1))-session-\(index).jsonl",
                contents: contents)
        }

        let archivedStart = baseDay.addingTimeInterval(TimeInterval(22 * 3600))
        let archivedContents = try self.sessionJSONL(
            id: "archived-newest",
            startedAt: archivedStart,
            userMessage: "Archived newest",
            items: [
                .functionCall(name: "exec_command", arguments: ["cmd": "pnpm lint"]),
                .functionCallOutput(output: "Command: lint\nWall time: 7.0 seconds\nProcess exited with code 1"),
            ])
        _ = try env.writeCodexArchivedSessionFile(
            filename: "rollout-2026-03-31-archived-newest.jsonl",
            contents: archivedContents)

        let loader = CodexSessionAnalyticsLoader(env: ["CODEX_HOME": env.codexHomeRoot.path])
        let snapshot = try #require(try loader.loadSnapshot())

        #expect(snapshot.sessions.count == 20)
        #expect(snapshot.sessions.first?.id == "archived-newest")
        #expect(snapshot.sessions.last?.id == "session-2")
        #expect(snapshot.sessionsAnalyzed == 20)
        #expect(snapshot.recentSessions.count == 8)
        #expect(snapshot.topTools.first == CodexToolAggregate(name: "exec_command", callCount: 20))
        #expect(snapshot.sessions.contains(where: { $0.id == "session-5" && $0.toolFailureCount == 0 }))
        #expect(snapshot.sessions.contains(where: { $0.id == "archived-newest" && $0.longRunningCallCount == 1 }))
        #expect(snapshot.sessions.contains(where: { $0.id == "session-2" && $0.verificationAttemptCount == 2 }))
        #expect(snapshot.toolFailureRate > 0)
        #expect(snapshot.medianSessionDurationSeconds > 0)
        #expect(snapshot.medianToolCallsPerSession == 2)
    }

    @Test
    func `loader falls back to home dot codex when CODEX_HOME is unset`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-analytics-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dotCodex = root.appendingPathComponent(".codex", isDirectory: true)
        let sessions = dotCodex.appendingPathComponent("sessions/2026/03/29", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let startedAt = Date(timeIntervalSince1970: 1_743_206_400)
        let fileURL = sessions.appendingPathComponent("rollout-2026-03-29-home.jsonl")
        try self.sessionJSONL(
            id: "home-session",
            startedAt: startedAt,
            userMessage: "Home fallback",
            items: [
                .functionCall(name: "exec_command", arguments: ["cmd": "swift build"]),
                .functionCallOutput(output: "Command: build\nWall time: 5.2 seconds\nProcess exited with code 0"),
            ])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = CodexSessionAnalyticsLoader(env: [:], homeDirectoryURL: root)
        let snapshot = try #require(try loader.loadSnapshot())

        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.id == "home-session")
        #expect(snapshot.sessions.first?.verificationAttemptCount == 1)
    }
}

extension CodexSessionAnalyticsLoaderTests {
    fileprivate enum SessionItem {
        case functionCall(name: String, arguments: [String: String])
        case functionCallOutput(output: String)
    }

    private func sessionJSONL(
        id: String,
        startedAt: Date,
        userMessage: String,
        items: [SessionItem],
        includeMalformedLine: Bool = false) throws -> String
    {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = []
        let sessionMeta: [String: Any] = [
            "timestamp": formatter.string(from: startedAt),
            "type": "session_meta",
            "payload": [
                "id": id,
                "timestamp": formatter.string(from: startedAt),
            ],
        ]
        let userMessageEvent: [String: Any] = [
            "timestamp": formatter.string(from: startedAt.addingTimeInterval(0.1)),
            "type": "event_msg",
            "payload": [
                "type": "user_message",
                "message": userMessage,
            ],
        ]

        try lines.append(self.jsonLine(sessionMeta))
        try lines.append(self.jsonLine(userMessageEvent))
        if includeMalformedLine {
            lines.append("{not-json")
        }

        for (index, item) in items.enumerated() {
            let timestamp = formatter.string(from: startedAt.addingTimeInterval(Double(index + 1)))
            switch item {
            case let .functionCall(name, arguments):
                let payload: [String: Any] = try [
                    "type": "function_call",
                    "name": name,
                    "arguments": self.jsonString(arguments),
                    "call_id": "call-\(id)-\(index)",
                ]
                try lines.append(self.jsonLine([
                    "timestamp": timestamp,
                    "type": "response_item",
                    "payload": payload,
                ]))

            case let .functionCallOutput(output):
                let payload: [String: Any] = [
                    "type": "function_call_output",
                    "call_id": "call-\(id)-\(index)",
                    "output": output,
                ]
                try lines.append(self.jsonLine([
                    "timestamp": timestamp,
                    "type": "response_item",
                    "payload": payload,
                ]))
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private func jsonString(_ object: [String: String]) throws -> String {
        try self.jsonLine(object)
    }
}
