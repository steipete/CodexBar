import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudePriceRangeTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static let start = Date(timeIntervalSince1970: 1_727_784_000) // 2024-10-01 noon UTC
    private static let model = "claude-sonnet-4-20250514"

    private static func day(_ index: Int) -> Date {
        self.start.addingTimeInterval(Double(index) * 86400)
    }

    private static func entry(
        day: Int,
        id: String? = nil,
        request: String? = nil,
        input: Int = 10,
        output: Int = 2,
        incomplete: Bool = false,
        sidechain: Bool = false) -> [String: Any]
    {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output]
        if !incomplete, input > 0 {
            usage["cache_read_input_tokens"] = 3
            usage["cache_creation_input_tokens"] = 4
            usage["cache_creation"] = ["ephemeral_1h_input_tokens": 2]
        }
        var message: [String: Any] = ["model": self.model, "usage": usage, "metadata": ["sessionId": "fallback"]]
        message["id"] = id
        if incomplete { message["stop_reason"] = NSNull() }
        var row: [String: Any] = [
            "type": "assistant", "timestamp": self.day(day).ISO8601Format(),
            "isSidechain": sidechain, "message": message,
        ]
        row["requestId"] = request
        return row
    }

    @Test(arguments: [false, true])
    func `range rejection preserves golden rows streaming winners and byte offsets`(vertex: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let range = CostUsageScanner.CostUsageDayRange(
            since: Self.day(700), until: Self.day(729), calendar: Self.calendar)
        var entries = [
            Self.entry(day: 0, id: "a", request: "request"),
            Self.entry(day: 700, id: "a", request: "request", output: 0, incomplete: true),
            Self.entry(day: 700, id: "a", request: "request", output: 4),
            Self.entry(day: 700, id: "a", request: "request", input: 999, output: 0, incomplete: true),
            Self.entry(day: 730, id: "a", request: "request", output: 6, sidechain: true),
            Self.entry(day: 731, id: "a", request: "request", output: 99),
            Self.entry(day: 701, id: "b", output: 0, incomplete: true),
            Self.entry(day: 702, id: "c", output: 3),
            Self.entry(day: 702, id: "c", input: 0, output: 0),
            Self.entry(day: 699, sidechain: true),
            Self.entry(day: 698),
            Self.entry(day: 729),
            ["type": "assistant", "timestamp": Self.day(700).ISO8601Format(), "usage": [:]],
            ["type": "assistant", "timestamp": "invalid", "message": ["usage": [:]]],
        ]
        if vertex {
            for index in entries.indices {
                entries[index]["metadata"] = ["provider": "vertex"]
            }
        }
        let prefix = try env.jsonl([entries.removeFirst()])
        let complete = try prefix + (env.jsonl(entries))
        let content = complete + #"{"type":"assistant","message":{"usage":"#
        let file = try env.writeClaudeProjectFile(relativePath: "project/subagents/range.jsonl", contents: content)
        let expected = [
            Self.expected(day: 730, id: "a", request: "request", output: 6, sidechain: true),
            Self.expected(day: 701, id: "b", output: 0, incomplete: true),
            Self.expected(day: 702, id: "c", output: 3),
            Self.expected(day: 699, sidechain: true),
            Self.expected(day: 729),
        ]
        for filter: CostUsageScanner.ClaudeLogProviderFilter in [.all, .excludeVertexAI, .vertexAIOnly] {
            for offset in [Int64(0), Int64(prefix.utf8.count)] {
                let parsed = CostUsageScanner.parseClaudeFile(
                    fileURL: file,
                    range: range,
                    providerFilter: filter,
                    startOffset: offset,
                    modelsDevCatalog: ModelsDevCatalog(providers: [:]))
                let keep = filter == .all || (filter == .vertexAIOnly) == vertex
                #expect(parsed.rows == (keep ? expected : []))
                #expect(parsed.parsedBytes == Int64(complete.utf8.count))
            }
        }
    }

    @Test
    func `two years of usage only prices rows in the padded thirty day scan range`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let content = try env.jsonl((0..<730).map { Self.entry(day: $0) })
        let file = try env.writeClaudeProjectFile(relativePath: "project/history.jsonl", contents: content)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let parsed = CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            CostUsageScanner.parseClaudeFile(
                fileURL: file,
                range: .init(since: Self.day(700), until: Self.day(729), calendar: Self.calendar),
                providerFilter: .excludeVertexAI,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        }
        #expect(parsed.rows == (699..<730).map { Self.expected(day: $0, pathRole: .parent) })
        #expect(parsed.parsedBytes == Int64(content.utf8.count))
        #expect(recorder.snapshot().claudeLineDecodes == 730)
        #expect(recorder.snapshot().claudeCostCalculations == parsed.rows.count)
    }

    private static func expected(
        day: Int,
        id: String? = nil,
        request: String? = nil,
        output: Int = 2,
        incomplete: Bool = false,
        sidechain: Bool = false,
        pathRole: CostUsageScanner.ClaudePathRole = .subagent) -> CostUsageScanner.ClaudeUsageRow
    {
        // Sonnet 4: input $3/M, output $15/M, read $0.30/M, 5m creation $3.75/M, 1h creation $6/M.
        let nanos = incomplete ? 0 : 50400 + output * 15000
        return CostUsageScanner.ClaudeUsageRow(
            dayKey: CostUsageScanner.CostUsageDayRange.dayKey(from: self.day(day), calendar: self.calendar),
            model: self.model,
            sessionId: "fallback",
            messageId: id,
            requestId: request,
            timestampUnixMs: Int64(self.day(day).timeIntervalSince1970 * 1000),
            isSidechain: sidechain,
            pathRole: pathRole,
            input: 10,
            cacheRead: incomplete ? 0 : 3,
            cacheCreate: incomplete ? 0 : 4,
            cacheCreate1h: incomplete ? 0 : 2,
            output: output,
            costNanos: nanos,
            costPriced: !incomplete,
            isIncomplete: incomplete ? true : nil)
    }
}
