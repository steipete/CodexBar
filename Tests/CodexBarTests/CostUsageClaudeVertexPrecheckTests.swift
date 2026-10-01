import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeVertexPrecheckTests {
    private static let plain = #"{"type":"assistant","timestamp":"2026-09-29T12:00:00Z","#
        + #""metadata":{"provider":"anthropic"},"message":{"model":"claude-sonnet-4-6","#
        + #""content":[{"type":"tool_use","input":{"text":"synthetic payload"}}],"#
        + #""usage":{"input_tokens":10,"output_tokens":2}}}"#

    private static let nonVertexContent = [
        "@MainActor func render() {}", "import @scope/package", "fixture@example.test",
        "@decorator", "msg_vrtx_unrelated",
    ]

    @Test
    func `raw escaped and Unicode markers preserve full walk filter results`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 29)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: .current)
        var lines = [Self.plain]
        for content in Self.nonVertexContent + [#"\u0040MainActor"#, #"msg_\u0076rtx_unrelated"#] {
            lines.append(Self.plain.replacingOccurrences(of: "synthetic payload", with: content))
        }
        for metadata in [
            #"{"provider":"Vertex"}"#, #"{"provider":"GCP"}"#, #"{"gcp_project":false}"#,
            #"{"myVeRtExFlag":null}"#, #"{"nested":[{"backend":"VERTEX"}]}"#,
            #"{"nested":[[{"backend":"VERTEX"}]]}"#, #"{"nested":["vertex","gcp"]}"#,
            #"{"provider":"\u0076\u0065\u0072\u0074\u0065\u0078"}"#,
            #"{"provider":"\u0056\u0045\u0052\u0054\u0045\u0058"}"#,
            #"{"provider":"\u0056\u0045\u0052\u0054\u0045\u0058\u0301"}"#,
            #"{"\u0067\u0063\u0070":false}"#, #"{"\u0047\u0043\u0050":false}"#,
            #"{"provider":"ver\u0074ex"}"#, #"{"provider":"not a \\u0076 marker"}"#,
            #"{"provider":"日本VERTEX🦞"}"#, #"{"provider":"vertex\u0301"}"#,
            #"{"provider":"vértex"}"#, #"{"provider":"ve\u0301rtex"}"#,
            #"{"provider":"ｖｅｒｔｅｘ"}"#, #"{"provider":"ver\u200dtex"}"#,
            #"{"gcp\u0301":false}"#, #"{"éGCP":false}"#,
            #"{"café":{"provider":"vertex"},"cafe\u0301":{"provider":"vertex"}}"#,
        ] {
            lines.append(Self.plain.replacingOccurrences(of: #"{"provider":"anthropic"}"#, with: metadata))
        }
        for id in [
            #"msg_vrtx_123"#,
            #"req_vrtx_123"#,
            #"msg_VRTX_123"#,
            #"msg_\u0076rtx_123"#,
            #"msg\u005Frtx_123"#,
            #"msg\u005fvrtx_123"#,
            #"msg_\u0076rtx\u005F123"#,
        ] {
            lines.append(Self.plain.replacingOccurrences(
                of: #""model":"claude-sonnet-4-6""#,
                with: #""id":"\#(id)","model":"claude-sonnet-4-6""#))
            lines.append(Self.plain.replacingOccurrences(
                of: #""metadata":"#,
                with: #""requestId":"\#(id)","metadata":"#))
        }
        for model in [
            #"claude-test@date"#,
            #"claude-test\u0040date"#,
            #"other@date"#,
            #"claude-test＠date"#,
            #"claude-test@\u0301date"#,
        ] {
            lines.append(Self.plain.replacingOccurrences(of: "claude-sonnet-4-6", with: model))
        }
        for (index, line) in lines.enumerated() {
            let decoded = try #require(try ClaudeJSONObject.decode(Data(line.utf8)))
            let vertex = CostUsageScanner.isVertexAIUsageEntry(obj: decoded)
            let file = try env.writeClaudeProjectFile(relativePath: "golden/session.jsonl", contents: line + "\n")
            let all = CostUsageScanner.parseClaudeFile(
                fileURL: file, range: range, providerFilter: .all, modelsDevCatalog: ModelsDevCatalog(providers: [:]))
            #expect(all.rows.count == 1, "fixture \(index)")
            for filter in [CostUsageScanner.ClaudeLogProviderFilter.all, .excludeVertexAI, .vertexAIOnly] {
                let keep = filter == .all || (filter == .vertexAIOnly ? vertex : !vertex)
                let actual = CostUsageScanner.parseClaudeFile(
                    fileURL: file,
                    range: range,
                    providerFilter: filter,
                    modelsDevCatalog: ModelsDevCatalog(providers: [:]))
                #expect(actual.rows == (keep ? all.rows : []), "fixture \(index), filter \(filter)")
                #expect(actual.parsedBytes == all.parsedBytes)
            }
        }
    }

    @Test
    func `content only id and model markers never require metadata walks`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 29)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: .current)
        for content in Self.nonVertexContent {
            let line = Self.plain.replacingOccurrences(of: "synthetic payload", with: content)
            let file = try env.writeClaudeProjectFile(
                relativePath: "content/session.jsonl", contents: String(repeating: line + "\n", count: 100))
            for filter in [CostUsageScanner.ClaudeLogProviderFilter.all, .excludeVertexAI, .vertexAIOnly] {
                let work = CostUsageScanner.ClaudeScanWorkRecorder()
                let parsed = CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
                    CostUsageScanner.parseClaudeFile(
                        fileURL: file,
                        range: range,
                        providerFilter: filter,
                        modelsDevCatalog: ModelsDevCatalog(providers: [:]))
                }
                #expect(parsed.rows.count == (filter == .vertexAIOnly ? 0 : 100))
                #expect(parsed.parsedBytes == Int64((line.utf8.count + 1) * 100))
                #expect(work.snapshot().claudeLineDecodes == 100)
                #expect(work.snapshot().vertexMetadataWalks == 0, "\(content), \(filter)")
            }
        }
    }

    @Test
    func `plain lines avoid metadata walks while marked lines retain them`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 29)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: .current)
        for marked in [false, true] {
            let line = marked ? Self.plain.replacingOccurrences(of: "anthropic", with: "Vertex") : Self.plain
            let file = try env.writeClaudeProjectFile(
                relativePath: "counter/session.jsonl", contents: String(repeating: line + "\n", count: 100))
            for filter in [CostUsageScanner.ClaudeLogProviderFilter.all, .excludeVertexAI, .vertexAIOnly] {
                let work = CostUsageScanner.ClaudeScanWorkRecorder()
                let parsed = CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
                    CostUsageScanner.parseClaudeFile(
                        fileURL: file,
                        range: range,
                        providerFilter: filter,
                        modelsDevCatalog: ModelsDevCatalog(providers: [:]))
                }
                let keep = filter == .all || (filter == .vertexAIOnly ? marked : !marked)
                #expect(parsed.rows.count == (keep ? 100 : 0))
                #expect(parsed.parsedBytes == Int64((line.utf8.count + 1) * 100))
                #expect(work.snapshot().claudeLineDecodes == (!marked && filter == .vertexAIOnly ? 0 : 100))
                if marked, filter != .all {
                    #expect(work.snapshot().vertexMetadataWalks >= 100)
                } else {
                    #expect(work.snapshot().vertexMetadataWalks == 0)
                }
            }
        }
    }
}
