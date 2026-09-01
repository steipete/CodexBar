import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeMetadataParsingTests {
    @Test(arguments: [false, true])
    func `decoded scalar coercion and session fallback preserve complete rows`(vertex: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 29)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let provider: UsageProvider = vertex ? .vertexai : .claude
        let filter: CostUsageScanner.ClaudeLogProviderFilter = vertex ? .vertexAIOnly : .excludeVertexAI
        let inputs: [Any] = [false, true, 2, -1, 1.75, "2", NSNull()]
        let expectedInputs = [0, 1, 2, 0, 1, 0, 0]
        let sidechains: [Any] = [false, true, 2, -1, 0, "true", NSNull()]
        let expectedSidechains = [false, true, true, true, false, false, false]
        let hours: [Any] = [false, true, 99, -1, 1.75, "2", NSNull()]
        let expectedHours = [0, 1, 3, 0, 1, 0, 0]
        let sessions: [String?] = ["root", "snake", "metadata", "message", nil, nil, nil]
        let models = ["claude-test-café", "claude-test-cafe\u{301}", "anthropic.anthropic.example"]
        var entries: [[String: Any]] = []
        var expectedRows: [CostUsageScanner.ClaudeUsageRow] = []
        for index in inputs.indices {
            let model = models[index % models.count]
            var metadata: [String: Any] = ["provider": vertex ? "vertex" : "anthropic", "café": [:]]
            if index < 3 { metadata["sessionId"] = "metadata" }
            let messageMetadata: [String: Any] = index < 4 ? ["sessionId": "message"] : [:]
            var entry: [String: Any] = [
                "type": "assistant", "timestamp": env.isoString(for: day), "isSidechain": sidechains[index],
                "metadata": metadata, "requestId": index == 0 ? "request" : NSNull(),
                "sessionId": index == 0 ? "root" : false,
                "message": [
                    "model": model, "id": index == 0 ? "message" : NSNumber(value: index),
                    "metadata": messageMetadata,
                    "usage": [
                        "input_tokens": inputs[index], "output_tokens": true, "cache_read_input_tokens": "2",
                        "cache_creation_input_tokens": 3,
                        "cache_creation": ["ephemeral_1h_input_tokens": hours[index]],
                    ],
                ],
            ]
            if index < 2 { entry["session_id"] = "snake" }
            entries.append(entry)
            expectedRows.append(CostUsageScanner.ClaudeUsageRow(
                dayKey: dayKey,
                model: CostUsagePricing.normalizeClaudeModel(model),
                sessionId: sessions[index],
                messageId: index == 0 ? "message" : nil,
                requestId: index == 0 ? "request" : nil,
                timestampUnixMs: Int64((day.timeIntervalSince1970 * 1000).rounded()),
                isSidechain: expectedSidechains[index],
                pathRole: .subagent,
                input: expectedInputs[index],
                cacheRead: 0,
                cacheCreate: 3,
                cacheCreate1h: expectedHours[index],
                output: 1,
                costNanos: 0,
                costPriced: false))
        }
        let content = try env.jsonl(entries).replacingOccurrences(of: "sessionId", with: #"session\u0049d"#)
        let file = try env.writeClaudeProjectFile(relativePath: "project/subagents/scalars.jsonl", contents: content)
        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: file,
            range: .init(since: day, until: day),
            providerFilter: filter,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        #expect(parsed.rows == expectedRows)
        #expect(parsed.rows.map { Array($0.model.utf8) } == expectedRows.map { Array($0.model.utf8) })
        #expect(parsed.parsedBytes == Int64(content.utf8.count))
        let options = CostUsageScanner.Options(claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        let report = CostUsageScanner.loadDailyReport(
            provider: provider, since: day, until: day, now: day, options: options)
        let cache = CostUsageClaudeCacheIO.load(provider: provider, cacheRoot: env.cacheRoot)
        #expect(cache.files.values.flatMap { $0.claudeRows ?? [] } == expectedRows)
        #expect(cache.files.values.map(\.parsedBytes) == [parsed.parsedBytes])
        #expect(report.summary?.totalTokens == 32)
        #expect(report.summary?.totalCostUSD == nil)
        #expect(cache.days[dayKey]?.values.reduce(0) { $0 + $1[5] } == 7)
        #expect(cache.days[dayKey]?.values.allSatisfy { $0[6] == 0 } == true)
    }

    @Test
    func `JSONSerialization rejection and trailing comma acceptance preserve bytes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 29)
        let valid = """
        {"type":"assistant","timestamp":"\(env
            .isoString(for: day))","message":{"model":"claude-test-unknown","usage":{"input_tokens":2,}}}
        """
        let malformed = [
            #"{"type":"assistant","usage":NaN}"#,
            #"{"type":"assistant","usage":"\uD800"}"#,
            #"{"type":"assistant","usage":null"#,
            #"{"type":"assistant","usage":null} trailing"#,
        ]
        for raw in malformed {
            #expect((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) == nil)
        }
        #expect(try JSONSerialization.jsonObject(with: Data(valid.utf8)) is NSDictionary)
        let rejectedRoots = ["[\(valid)]", "[]", "null", "2", #"{"type":"assistant","usage":null}"#]
        let content = (malformed + rejectedRoots + [valid]).joined(separator: "\n") + "\n"
        let file = try env.writeClaudeProjectFile(relativePath: "project/malformed.jsonl", contents: content)
        for filter: CostUsageScanner.ClaudeLogProviderFilter in [.all, .excludeVertexAI, .vertexAIOnly] {
            let parsed = CostUsageScanner.parseClaudeFile(
                fileURL: file,
                range: .init(since: day, until: day),
                providerFilter: filter,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]))
            #expect(parsed.rows.count == (filter == .vertexAIOnly ? 0 : 1))
            #expect(parsed.rows.allSatisfy { $0.input == 2 && $0.model == "claude-test-unknown" })
            #expect(parsed.parsedBytes == Int64(content.utf8.count))
        }
    }
}
