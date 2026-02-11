import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct QwenCodeUsageProbeTests {
    @Test
    func aggregatesDailyUsageFromLogs() throws {
        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: baseDir) }

        let chatsDir = baseDir
            .appendingPathComponent("projects")
            .appendingPathComponent("sample-project")
            .appendingPathComponent("chats")
        try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12, minute: 0))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let todayStamp = formatter.string(from: now)
        let yesterdayStamp = formatter.string(from: yesterday)

        let todayLine = "{\"type\":\"assistant\",\"timestamp\":\"\(todayStamp)\",\"usageMetadata\":"
            + "{\"promptTokenCount\":10,\"candidatesTokenCount\":20,\"totalTokenCount\":30}}"
        let yesterdayLine = "{\"type\":\"assistant\",\"timestamp\":\"\(yesterdayStamp)\",\"usageMetadata\":"
            + "{\"promptTokenCount\":5,\"candidatesTokenCount\":5,\"totalTokenCount\":10}}"
        let lines = [
            todayLine,
            yesterdayLine,
            "{\"type\":\"user\",\"timestamp\":\"\(todayStamp)\"}",
        ]
        let logURL = chatsDir.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let probe = QwenCodeUsageProbe(requestLimit: 100, baseDirectory: baseDir, now: now)
        let snapshot = try probe.fetch()

        #expect(snapshot.requests == 1)
        #expect(snapshot.totalTokens == 30)

        let usage = snapshot.toUsageSnapshot(requestLimit: 100)
        #expect(usage.primary?.usedPercent == 1)
    }

    @Test
    func throwsWhenProjectsDirectoryMissing() {
        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: baseDir) }
        let now = Date()

        let probe = QwenCodeUsageProbe(requestLimit: 100, baseDirectory: baseDir, now: now)

        #expect(throws: QwenCodeUsageProbeError.self) {
            try probe.fetch()
        }
    }

    @Test
    func throwsWhenRequestLimitInvalid() {
        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: baseDir) }

        let probe = QwenCodeUsageProbe(requestLimit: 0, baseDirectory: baseDir)

        #expect(throws: QwenCodeUsageProbeError.self) {
            try probe.fetch()
        }
    }
}
