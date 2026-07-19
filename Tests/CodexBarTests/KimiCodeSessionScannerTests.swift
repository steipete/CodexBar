import CodexBarCore
import Foundation
import Testing

struct KimiCodeSessionScannerTests {
    @Test
    func `scanner aggregates turn usage across main and subagents without reading other events`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root
            .appendingPathComponent("sessions/workspace/session-a/agents/main", isDirectory: true)
        let child = root
            .appendingPathComponent("sessions/workspace/session-a/agents/agent-0", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_784_347_200)
        try Self.write([
            Self.usage(time: 1_784_257_200_000, model: "kimi-code/k3", input: 10, cacheRead: 20, output: 3),
            #"{"type":"assistant.message","time":1784257200000,"content":"must not be parsed"}"#,
            Self.usage(
                time: 1_784_257_300_000,
                model: "kimi-code/k3",
                input: 4,
                cacheRead: 5,
                cacheCreation: 6,
                output: 7),
            Self.usage(
                time: 1_784_257_400_000,
                model: "kimi-code/k3",
                scope: "session",
                input: 999,
                cacheRead: 999,
                output: 999),
        ], to: main.appendingPathComponent("wire.jsonl"))
        try Self.write([
            Self.usage(
                time: 1_784_343_600_000,
                model: "kimi-code/kimi-for-coding",
                input: 8,
                cacheRead: 9,
                output: 10),
        ], to: child.appendingPathComponent("wire.jsonl"))

        let snapshot = try #require(KimiCodeSessionScanner.scan(
            environment: [KimiSettingsReader.codeHomeEnvironmentKey: root.path],
            historyDays: 30,
            now: now,
            calendar: Self.calendar))

        #expect(snapshot.currencyCode == "XXX")
        #expect(snapshot.last30DaysTokens == 82)
        #expect(snapshot.last30DaysRequests == 3)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.map(\.modelName) == [
            "kimi-code/k3",
            "kimi-code/kimi-for-coding",
        ])
        #expect(snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.map(\.totalTokens) == [55, 27])
        #expect(snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.map(\.inputTokens) == [14, 8])
        #expect(snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.map(\.cacheReadTokens) == [25, 9])
        #expect(snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.map(\.cacheCreationTokens) == [6, 0])
        #expect(snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.map(\.outputTokens) == [10, 10])
    }

    @Test
    func `scanner ignores malformed negative and out of range records`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root
            .appendingPathComponent("sessions/workspace/session-a/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try Self.write([
            Self.usage(
                time: 1_784_257_200_000,
                model: "kimi-code/k3",
                input: -1,
                cacheRead: 2,
                output: 3),
            Self.usage(
                time: 1_770_000_000_000,
                model: "kimi-code/k3",
                input: 10,
                cacheRead: 20,
                output: 30),
            #"{"type":"usage.record","time":"bad","model":"kimi-code/k3","usageScope":"turn","usage":{}}"#,
        ], to: agent.appendingPathComponent("wire.jsonl"))

        #expect(KimiCodeSessionScanner.scan(
            environment: [KimiSettingsReader.codeHomeEnvironmentKey: root.path],
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_784_347_200),
            calendar: Self.calendar) == nil)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func usage(
        time: Int64,
        model: String,
        scope: String = "turn",
        input: Int,
        cacheRead: Int,
        cacheCreation: Int = 0,
        output: Int) -> String
    {
        """
        {"type":"usage.record","time":\(time),"model":"\(model)","usageScope":"\(scope)","usage":{"inputOther":\(
            input),"inputCacheRead":\(cacheRead),"inputCacheCreation":\(cacheCreation),"output":\(output)}}
        """
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
