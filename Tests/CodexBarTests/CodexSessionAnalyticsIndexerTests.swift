import Foundation
import Testing
@testable import CodexBarCore

struct CodexSessionAnalyticsIndexerTests {
    @Test
    func `indexer loads persisted analytics without rollout files`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let startedAt = try env.makeLocalNoon(year: 2026, month: 3, day: 28)
        let contents = try self.sessionJSONL(
            id: "persisted-session",
            startedAt: startedAt,
            userMessage: "Persisted session",
            items: [
                .functionCall(
                    offset: 1,
                    name: "exec_command",
                    callID: "persisted-exec",
                    arguments: ["cmd": "swift test"]),
                .functionCallOutput(
                    offset: 2,
                    callID: "persisted-exec",
                    output: "Command: test\nWall time: 1 second\nProcess exited with code 0"),
            ])
        let fileURL = try env.writeCodexSessionFile(
            day: startedAt,
            filename: "rollout-persisted-session.jsonl",
            contents: contents)

        let indexer = CodexSessionAnalyticsIndexer(
            env: ["CODEX_HOME": env.codexHomeRoot.path],
            cacheRoot: env.cacheRoot)
        _ = try indexer.refreshIndex(existing: nil, now: startedAt)
        try FileManager.default.removeItem(at: fileURL)

        let persisted = try #require(indexer.loadPersistedIndex())
        let snapshot = try #require(
            CodexSessionAnalyticsSnapshotBuilder.buildSnapshot(
                from: persisted,
                maxSessions: 20,
                now: startedAt))

        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.id == "persisted-session")
    }

    @Test
    func `indexer skips reparse when fingerprint is unchanged`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let startedAt = try env.makeLocalNoon(year: 2026, month: 3, day: 29)
        let contents = try self.sessionJSONL(
            id: "fingerprint-stable",
            startedAt: startedAt,
            userMessage: "Stable fingerprint",
            items: [
                .functionCall(
                    offset: 1,
                    name: "exec_command",
                    callID: "stable-exec",
                    arguments: ["cmd": "swift build"]),
                .functionCallOutput(
                    offset: 2,
                    callID: "stable-exec",
                    output: "Command: build\nWall time: 1 second\nProcess exited with code 0"),
            ])
        let fileURL = try env.writeCodexSessionFile(
            day: startedAt,
            filename: "rollout-fingerprint-stable.jsonl",
            contents: contents)

        let indexer = CodexSessionAnalyticsIndexer(
            env: ["CODEX_HOME": env.codexHomeRoot.path],
            cacheRoot: env.cacheRoot)
        let firstIndex = try indexer.refreshIndex(existing: nil, now: startedAt)
        let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let originalMtime = try #require(resourceValues.contentModificationDate)
        let originalSize = try #require(resourceValues.fileSize)

        let invalidData = Data(repeating: 0x78, count: originalSize)
        try invalidData.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: fileURL.path)

        let secondIndex = try indexer.refreshIndex(existing: firstIndex, now: startedAt.addingTimeInterval(60))
        let snapshot = try #require(
            CodexSessionAnalyticsSnapshotBuilder.buildSnapshot(
                from: secondIndex,
                maxSessions: 20,
                now: startedAt))

        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.title == "Stable fingerprint")
        #expect(secondIndex.parseErrorsByPath.isEmpty)
    }

    @Test
    func `indexer keeps prior summary when changed rollout becomes malformed`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let startedAt = try env.makeLocalNoon(year: 2026, month: 3, day: 30)
        let contents = try self.sessionJSONL(
            id: "malformed-retry",
            startedAt: startedAt,
            userMessage: "Retry malformed",
            items: [
                .functionCall(
                    offset: 1,
                    name: "exec_command",
                    callID: "retry-exec",
                    arguments: ["cmd": "swift test"]),
                .functionCallOutput(
                    offset: 2,
                    callID: "retry-exec",
                    output: "Command: test\nWall time: 1 second\nProcess exited with code 0"),
            ])
        let fileURL = try env.writeCodexSessionFile(
            day: startedAt,
            filename: "rollout-malformed-retry.jsonl",
            contents: contents)

        let indexer = CodexSessionAnalyticsIndexer(
            env: ["CODEX_HOME": env.codexHomeRoot.path],
            cacheRoot: env.cacheRoot)
        let firstIndex = try indexer.refreshIndex(existing: nil, now: startedAt)

        try "{not-json".write(to: fileURL, atomically: true, encoding: .utf8)

        let secondIndex = try indexer.refreshIndex(existing: firstIndex, now: startedAt.addingTimeInterval(60))
        let snapshot = try #require(
            CodexSessionAnalyticsSnapshotBuilder.buildSnapshot(
                from: secondIndex,
                maxSessions: 20,
                now: startedAt))

        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.id == "malformed-retry")
        #expect(!secondIndex.parseErrorsByPath.isEmpty)
    }

    @Test
    func `snapshot builder prefers active file when duplicate session mtimes tie`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let startedAt = try env.makeLocalNoon(year: 2026, month: 3, day: 31)
        let activeURL = try env.writeCodexSessionFile(
            day: startedAt,
            filename: "rollout-duplicate-active.jsonl",
            contents: self.sessionJSONL(
                id: "duplicate-session",
                startedAt: startedAt,
                userMessage: "Active wins",
                items: []))
        let archivedURL = try env.writeCodexArchivedSessionFile(
            filename: "rollout-duplicate-archived.jsonl",
            contents: self.sessionJSONL(
                id: "duplicate-session",
                startedAt: startedAt,
                userMessage: "Archived loses",
                items: []))

        let sharedMtime = startedAt.addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: sharedMtime], ofItemAtPath: activeURL.path)
        try FileManager.default.setAttributes([.modificationDate: sharedMtime], ofItemAtPath: archivedURL.path)

        let indexer = CodexSessionAnalyticsIndexer(
            env: ["CODEX_HOME": env.codexHomeRoot.path],
            cacheRoot: env.cacheRoot)
        let index = try indexer.refreshIndex(existing: nil, now: startedAt.addingTimeInterval(180))
        let snapshot = try #require(
            CodexSessionAnalyticsSnapshotBuilder.buildSnapshot(
                from: index,
                maxSessions: 20,
                now: startedAt))

        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.title == "Active wins")
    }

    @Test
    func `refresh removes deleted rollout files from the index`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let startedAt = try env.makeLocalNoon(year: 2026, month: 4, day: 1)
        _ = try env.writeCodexSessionFile(
            day: startedAt,
            filename: "rollout-kept.jsonl",
            contents: self.sessionJSONL(
                id: "kept-session",
                startedAt: startedAt,
                userMessage: "Kept session",
                items: []))
        let deletedURL = try env.writeCodexSessionFile(
            day: startedAt,
            filename: "rollout-deleted.jsonl",
            contents: self.sessionJSONL(
                id: "deleted-session",
                startedAt: startedAt.addingTimeInterval(60),
                userMessage: "Deleted session",
                items: []))

        let indexer = CodexSessionAnalyticsIndexer(
            env: ["CODEX_HOME": env.codexHomeRoot.path],
            cacheRoot: env.cacheRoot)
        let firstIndex = try indexer.refreshIndex(existing: nil, now: startedAt)
        #expect(firstIndex.files.count == 2)

        try FileManager.default.removeItem(at: deletedURL)
        let secondIndex = try indexer.refreshIndex(existing: firstIndex, now: startedAt.addingTimeInterval(120))
        let snapshot = try #require(
            CodexSessionAnalyticsSnapshotBuilder.buildSnapshot(
                from: secondIndex,
                maxSessions: 20,
                now: startedAt))

        #expect(secondIndex.files.count == 1)
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.id == "kept-session")
    }
}

extension CodexSessionAnalyticsIndexerTests {
    fileprivate enum SessionItem {
        case functionCall(offset: TimeInterval, name: String, callID: String, arguments: [String: String])
        case functionCallOutput(offset: TimeInterval, callID: String, output: String)
    }

    private func sessionJSONL(
        id: String,
        startedAt: Date,
        userMessage: String,
        items: [SessionItem]) throws -> String
    {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = []
        try lines.append(self.jsonLine([
            "timestamp": formatter.string(from: startedAt),
            "type": "session_meta",
            "payload": [
                "id": id,
                "timestamp": formatter.string(from: startedAt),
            ],
        ]))
        try lines.append(self.jsonLine([
            "timestamp": formatter.string(from: startedAt.addingTimeInterval(0.1)),
            "type": "event_msg",
            "payload": [
                "type": "user_message",
                "message": userMessage,
            ],
        ]))

        for item in items {
            switch item {
            case let .functionCall(offset, name, callID, arguments):
                try lines.append(self.jsonLine([
                    "timestamp": formatter.string(from: startedAt.addingTimeInterval(offset)),
                    "type": "response_item",
                    "payload": [
                        "type": "function_call",
                        "name": name,
                        "arguments": self.jsonString(arguments),
                        "call_id": callID,
                    ],
                ]))
            case let .functionCallOutput(offset, callID, output):
                try lines.append(self.jsonLine([
                    "timestamp": formatter.string(from: startedAt.addingTimeInterval(offset)),
                    "type": "response_item",
                    "payload": [
                        "type": "function_call_output",
                        "call_id": callID,
                        "output": output,
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
