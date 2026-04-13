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
                        offset: 1,
                        name: "exec_command",
                        callID: "call-\(index)-exec",
                        arguments: ["cmd": index.isMultiple(of: 2) ? "swift test" : "rg Session"]),
                    .functionCallOutput(
                        offset: 2,
                        callID: "call-\(index)-exec",
                        output: "Command: exec\nWall time: 6.2 seconds\nProcess exited with code 0"),
                    .functionCall(
                        offset: 3,
                        name: index.isMultiple(of: 3) ? "write_stdin" : "mcp__vercel__get_project",
                        callID: "call-\(index)-followup",
                        arguments: ["chars": "npm test\n"]),
                    .functionCallOutput(
                        offset: 4,
                        callID: "call-\(index)-followup",
                        output: index.isMultiple(of: 4) ? "tool call error: handshake failed" :
                            "Command: second\nWall time: 120ms\nProcess exited with code 0"),
                    .tokenCount(
                        offset: 5,
                        totalTokens: 500 + index,
                        inputTokens: 250 + index,
                        cachedInputTokens: 50,
                        outputTokens: 200,
                        reasoningOutputTokens: 20),
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
                .functionCall(
                    offset: 1,
                    name: "exec_command",
                    callID: "archived-exec",
                    arguments: ["cmd": "pnpm lint"]),
                .functionCallOutput(
                    offset: 7,
                    callID: "archived-exec",
                    output: "Command: lint\nWall time: 7.0 seconds\nProcess exited with code 1"),
                .tokenCount(
                    offset: 8,
                    totalTokens: 999,
                    inputTokens: 444,
                    cachedInputTokens: 55,
                    outputTokens: 500,
                    reasoningOutputTokens: 99),
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
        #expect(snapshot.topTools.first?.name == "exec_command")
        #expect(snapshot.topTools.first?.callCount == 20)
        #expect(snapshot.topTools.first?.sessionCountUsingTool == 20)
        #expect(snapshot.sessions.contains(where: { $0.id == "session-5" && $0.toolFailureCount == 0 }))
        #expect(snapshot.sessions.contains(where: { $0.id == "archived-newest" && $0.longRunningCallCount == 1 }))
        #expect(snapshot.sessions.contains(where: { $0.id == "session-2" && $0.verificationAttemptCount == 2 }))
        #expect(snapshot.sessions.first?.tokenUsage?.totalTokens == 999)
        #expect(snapshot.summaryDiagnostics.sessionsWithTokens == 20)
        #expect(snapshot.summaryDiagnostics.sessionsWithFailures > 0)
        #expect(snapshot.toolFailureRate > 0)
        #expect(snapshot.medianSessionDurationSeconds > 0)
        #expect(snapshot.medianToolCallsPerSession == 2)
    }

    @Test
    func `loader honors maxSessions window and latest total token usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let baseDay = try env.makeLocalNoon(year: 2026, month: 3, day: 10)

        for index in 0..<12 {
            let start = baseDay.addingTimeInterval(TimeInterval(index * 3600))
            let contents = try self.sessionJSONL(
                id: "window-\(index)",
                startedAt: start,
                userMessage: "Window \(index)",
                items: [
                    .functionCall(
                        offset: 1,
                        name: "exec_command",
                        callID: "window-\(index)-exec",
                        arguments: ["cmd": "swift build"]),
                    .functionCallOutput(
                        offset: 2,
                        callID: "window-\(index)-exec",
                        output: "Command: build\nWall time: 2 seconds\nProcess exited with code 0"),
                    .tokenCount(
                        offset: 3,
                        totalTokens: 100 + index,
                        inputTokens: 50 + index,
                        cachedInputTokens: 10,
                        outputTokens: 40,
                        reasoningOutputTokens: 5),
                    .tokenCount(
                        offset: 4,
                        totalTokens: 200 + index,
                        inputTokens: 100 + index,
                        cachedInputTokens: 20,
                        outputTokens: 80,
                        reasoningOutputTokens: 10),
                ])
            _ = try env.writeCodexSessionFile(
                day: start,
                filename: "rollout-window-\(index).jsonl",
                contents: contents)
        }

        let loader = CodexSessionAnalyticsLoader(env: ["CODEX_HOME": env.codexHomeRoot.path])

        let snapshot10 = try #require(try loader.loadSnapshot(maxSessions: 10))
        #expect(snapshot10.sessions.count == 10)
        #expect(snapshot10.sessions.first?.id == "window-11")
        #expect(snapshot10.sessions.last?.id == "window-2")
        #expect(snapshot10.sessions.first?.tokenUsage?.totalTokens == 211)

        let snapshot20 = try #require(try loader.loadSnapshot(maxSessions: 20))
        #expect(snapshot20.sessions.count == 12)

        let snapshot50 = try #require(try loader.loadSnapshot(maxSessions: 50))
        #expect(snapshot50.sessions.count == 12)

        let snapshot100 = try #require(try loader.loadSnapshot(maxSessions: 100))
        #expect(snapshot100.sessions.count == 12)
    }

    @Test
    func `loader computes summary and per-tool diagnostics from call ids`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let baseDay = try env.makeLocalNoon(year: 2026, month: 3, day: 20)

        for (id, startOffset, title, items) in self.diagnosticSessions() {
            let startedAt = baseDay.addingTimeInterval(startOffset)
            let contents = try self.sessionJSONL(
                id: id,
                startedAt: startedAt,
                userMessage: title,
                items: items)
            _ = try env.writeCodexSessionFile(
                day: startedAt,
                filename: "rollout-\(id).jsonl",
                contents: contents)
        }

        let loader = CodexSessionAnalyticsLoader(env: ["CODEX_HOME": env.codexHomeRoot.path])
        let snapshot = try #require(try loader.loadSnapshot(maxSessions: 100))
        let diagnostics = snapshot.summaryDiagnostics

        #expect(snapshot.sessions.count == 4)
        #expect(diagnostics.windowSpanSeconds == 10800)
        #expect(diagnostics.sessionsWithTokens == 3)
        #expect(diagnostics.sessionsWithFailures == 2)
        #expect(diagnostics.sessionsWithChecks == 2)
        #expect(diagnostics.durationP25Seconds == 17.5)
        #expect(diagnostics.durationP50Seconds == 30)
        #expect(diagnostics.durationP75Seconds == 50)
        #expect(diagnostics.longestSessionDurationSeconds == 80)
        #expect(abs(diagnostics.top3DurationShare - (14.0 / 15.0)) < 0.0001)
        #expect(diagnostics.avgToolCalls == 2.5)
        #expect(diagnostics.toolCallsP75 == 3.25)
        #expect(diagnostics.sessionsOver50Calls == 0)
        #expect(diagnostics.sessionsOver100Calls == 0)
        #expect(diagnostics.maxToolCallsInSingleSession == 4)
        #expect(diagnostics.failedCalls == 2)
        #expect(diagnostics.totalCalls == 10)
        #expect(diagnostics.topFailingToolName == "exec_command")
        #expect(diagnostics.topFailingToolFailures == 1)

        let execTool = try #require(snapshot.topTools.first(where: { $0.name == "exec_command" }))
        #expect(execTool.callCount == 6)
        #expect(execTool.sessionCountUsingTool == 3)
        #expect(abs(execTool.callShare - 0.6) < 0.0001)
        #expect(execTool.averageCallsPerActiveSession == 2.0)
        #expect(execTool.maxCallsInSingleSession == 3)
        #expect(execTool.maxCallsSessionTitle == "Session four")
        #expect(execTool.failureCount == 1)
        #expect(abs(execTool.failureRate - (1.0 / 6.0)) < 0.0001)
        #expect(execTool.sessionsWithToolFailure == 1)
        #expect(execTool.longRunningCount == 1)

        let writeTool = try #require(snapshot.topTools.first(where: { $0.name == "write_stdin" }))
        #expect(writeTool.callCount == 3)
        #expect(writeTool.sessionCountUsingTool == 2)
        #expect(abs(writeTool.callShare - 0.3) < 0.0001)
        #expect(writeTool.averageCallsPerActiveSession == 1.5)
        #expect(writeTool.maxCallsInSingleSession == 2)
        #expect(writeTool.maxCallsSessionTitle == "Session two")
        #expect(writeTool.failureCount == 1)
        #expect(abs(writeTool.failureRate - (1.0 / 3.0)) < 0.0001)
        #expect(writeTool.sessionsWithToolFailure == 1)
        #expect(writeTool.longRunningCount == 1)
    }

    @Test
    func `loader ignores token events without total token usage and falls back to home dot codex`() throws {
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
                .functionCall(offset: 1, name: "exec_command", callID: "home-exec", arguments: ["cmd": "swift build"]),
                .functionCallOutput(
                    offset: 5.2,
                    callID: "home-exec",
                    output: "Command: build\nWall time: 5.2 seconds\nProcess exited with code 0"),
                .lastOnlyTokenCount(offset: 6, totalTokens: 999),
            ])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = CodexSessionAnalyticsLoader(env: [:], homeDirectoryURL: root)
        let snapshot = try #require(try loader.loadSnapshot())

        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.id == "home-session")
        #expect(snapshot.sessions.first?.verificationAttemptCount == 1)
        #expect(snapshot.sessions.first?.tokenUsage == nil)
    }
}

extension CodexSessionAnalyticsLoaderTests {
    fileprivate typealias DiagnosticSession = (String, TimeInterval, String, [SessionItem])

    fileprivate enum SessionItem {
        case functionCall(offset: TimeInterval, name: String, callID: String, arguments: [String: String])
        case functionCallOutput(offset: TimeInterval, callID: String, output: String)
        case tokenCount(
            offset: TimeInterval,
            totalTokens: Int,
            inputTokens: Int,
            cachedInputTokens: Int,
            outputTokens: Int,
            reasoningOutputTokens: Int)
        case lastOnlyTokenCount(offset: TimeInterval, totalTokens: Int)
    }

    private func diagnosticSessions() -> [DiagnosticSession] {
        [
            (
                "diagnostic-1",
                0,
                "Session one",
                [
                    .functionCall(
                        offset: 1,
                        name: "exec_command",
                        callID: "s1-exec-a",
                        arguments: ["cmd": "swift test"]),
                    .functionCallOutput(
                        offset: 5,
                        callID: "s1-exec-a",
                        output: "Command: test\nWall time: 6 seconds\nProcess exited with code 0"),
                    .functionCall(
                        offset: 6,
                        name: "exec_command",
                        callID: "s1-exec-b",
                        arguments: ["cmd": "rg foo"]),
                    .functionCallOutput(
                        offset: 10,
                        callID: "s1-exec-b",
                        output: "Command: rg\nWall time: 1 second\nProcess exited with code 2"),
                    .tokenCount(
                        offset: 10,
                        totalTokens: 1000,
                        inputTokens: 600,
                        cachedInputTokens: 100,
                        outputTokens: 300,
                        reasoningOutputTokens: 40),
                ]),
            (
                "diagnostic-2",
                3600,
                "Session two",
                [
                    .functionCall(
                        offset: 1,
                        name: "exec_command",
                        callID: "s2-exec",
                        arguments: ["cmd": "rg bar"]),
                    .functionCallOutput(
                        offset: 6,
                        callID: "s2-exec",
                        output: "Command: rg\nWall time: 1 second\nProcess exited with code 0"),
                    .functionCall(
                        offset: 8,
                        name: "write_stdin",
                        callID: "s2-write-a",
                        arguments: ["chars": "npm test\n"]),
                    .functionCallOutput(
                        offset: 15,
                        callID: "s2-write-a",
                        output: "tool call error: handshake failed"),
                    .functionCall(
                        offset: 16,
                        name: "write_stdin",
                        callID: "s2-write-b",
                        arguments: ["chars": "pnpm lint\n"]),
                    .functionCallOutput(
                        offset: 20,
                        callID: "s2-write-b",
                        output: "Command: lint\nWall time: 6 seconds\nProcess exited with code 0"),
                    .tokenCount(
                        offset: 20,
                        totalTokens: 2000,
                        inputTokens: 1100,
                        cachedInputTokens: 200,
                        outputTokens: 700,
                        reasoningOutputTokens: 90),
                ]),
            (
                "diagnostic-3",
                7200,
                "Session three",
                [
                    .functionCall(
                        offset: 1,
                        name: "write_stdin",
                        callID: "s3-write",
                        arguments: ["chars": "hello"]),
                    .functionCallOutput(
                        offset: 40,
                        callID: "s3-write",
                        output: "Command: echo\nWall time: 1 second\nProcess exited with code 0"),
                ]),
            (
                "diagnostic-4",
                10800,
                "Session four",
                [
                    .functionCall(
                        offset: 1,
                        name: "exec_command",
                        callID: "s4-exec-a",
                        arguments: ["cmd": "rg one"]),
                    .functionCallOutput(
                        offset: 20,
                        callID: "s4-exec-a",
                        output: "Command: rg\nWall time: 1 second\nProcess exited with code 0"),
                    .functionCall(
                        offset: 30,
                        name: "exec_command",
                        callID: "s4-exec-b",
                        arguments: ["cmd": "rg two"]),
                    .functionCallOutput(
                        offset: 50,
                        callID: "s4-exec-b",
                        output: "Command: rg\nWall time: 1 second\nProcess exited with code 0"),
                    .functionCall(
                        offset: 60,
                        name: "exec_command",
                        callID: "s4-exec-c",
                        arguments: ["cmd": "rg three"]),
                    .functionCallOutput(
                        offset: 70,
                        callID: "s4-exec-c",
                        output: "Command: rg\nWall time: 1 second\nProcess exited with code 0"),
                    .functionCall(
                        offset: 75,
                        name: "request_user_input",
                        callID: "s4-request",
                        arguments: ["question": "continue?"]),
                    .functionCallOutput(
                        offset: 80,
                        callID: "s4-request",
                        output: "accepted"),
                    .tokenCount(
                        offset: 80,
                        totalTokens: 3000,
                        inputTokens: 1700,
                        cachedInputTokens: 300,
                        outputTokens: 1000,
                        reasoningOutputTokens: 120),
                ]),
        ]
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

        for item in items {
            switch item {
            case let .functionCall(offset, name, callID, arguments):
                let payload: [String: Any] = try [
                    "type": "function_call",
                    "name": name,
                    "arguments": self.jsonString(arguments),
                    "call_id": callID,
                ]
                try lines.append(self.jsonLine([
                    "timestamp": formatter.string(from: startedAt.addingTimeInterval(offset)),
                    "type": "response_item",
                    "payload": payload,
                ]))

            case let .functionCallOutput(offset, callID, output):
                let payload: [String: Any] = [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output,
                ]
                try lines.append(self.jsonLine([
                    "timestamp": formatter.string(from: startedAt.addingTimeInterval(offset)),
                    "type": "response_item",
                    "payload": payload,
                ]))

            case let .tokenCount(
                offset,
                totalTokens,
                inputTokens,
                cachedInputTokens,
                outputTokens,
                reasoningOutputTokens):
                try lines.append(self.jsonLine([
                    "timestamp": formatter.string(from: startedAt.addingTimeInterval(offset)),
                    "type": "event_msg",
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "total_tokens": totalTokens,
                                "input_tokens": inputTokens,
                                "cached_input_tokens": cachedInputTokens,
                                "output_tokens": outputTokens,
                                "reasoning_output_tokens": reasoningOutputTokens,
                            ],
                        ],
                    ],
                ]))

            case let .lastOnlyTokenCount(offset, totalTokens):
                try lines.append(self.jsonLine([
                    "timestamp": formatter.string(from: startedAt.addingTimeInterval(offset)),
                    "type": "event_msg",
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "total_tokens": totalTokens,
                            ],
                        ],
                    ],
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
