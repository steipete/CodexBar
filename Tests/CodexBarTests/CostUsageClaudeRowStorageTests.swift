import Foundation
import Testing
@testable import CodexBarCore

@Suite(CostUsageClaudeCacheFixtures())
struct CostUsageClaudeRowStorageTests {
    private typealias Row = CostUsageScanner.ClaudeUsageRow
    private let sessions = ["synthetic-session-caf\u{e9}", "synthetic-session-cafe\u{301}", "synthetic-session-third"]
    private let models = ["claude-synthetic-model-a", "claude-synthetic-model-b"]

    private func row(_ index: Int) -> Row {
        Row(
            dayKey: "2026-10-04",
            model: self.models[index % 2],
            sessionId: self.sessions[index % 3],
            messageId: "synthetic-message-\(index)",
            requestId: "synthetic-request-\(index)",
            timestampUnixMs: 1_791_086_400_000,
            isSidechain: false,
            pathRole: .parent,
            input: index,
            cacheRead: 0,
            cacheCreate: 0,
            cacheCreate1h: nil,
            output: 1,
            costNanos: 0,
            costPriced: false,
            isIncomplete: nil)
    }

    private func identities(_ strings: [String]) throws -> Set<UInt> {
        try Set(strings.map { string in
            try #require(string.utf8.withContiguousStorageIfAvailable { UInt(bitPattern: $0.baseAddress) })
        })
    }

    private func assertShared(_ rows: [Row]) throws {
        #expect(rows.count == 10000)
        #expect(try self.identities(rows.compactMap(\.sessionId)).count == 3)
        #expect(try self.identities(rows.map(\.model)).count == 2)
        #expect(Set(rows.compactMap(\.sessionId).map { Data($0.utf8) }) == Set(self.sessions.map { Data($0.utf8) }))
    }

    @Test
    func `concurrent pool callers share exact spellings`() async throws {
        let pool = ClaudeRowStringPool()
        let sessions = self.sessions
        let strings = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<1000).map { pool.intern(sessions[$0 % sessions.count]) } }
            }
            var strings: [String] = []
            for await batch in group {
                strings.append(contentsOf: batch)
            }
            return strings
        }
        #expect(strings.count == 8000)
        #expect(try self.identities(strings).count == 3)
        #expect(Set(strings.map { Data($0.utf8) }) == Set(sessions.map { Data($0.utf8) }))
    }

    @Test(arguments: [CostUsageReportContext.regular, .spendDashboard])
    func `artifact decode shares storage and preserves every encoded byte`(context: CostUsageReportContext) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var artifact = CostUsageClaudeCache()
        artifact.usage.version = 4
        artifact.usage.files["/synthetic/first.jsonl"] = CostUsageFileUsage(
            mtimeUnixMs: 1, size: 1, days: [:], claudeRows: (0..<5000).map(self.row))
        artifact.usage.files["/synthetic/second.jsonl"] = CostUsageFileUsage(
            mtimeUnixMs: 1, size: 1, days: [:], claudeRows: (5000..<10000).map(self.row))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(artifact)
        let url = CostUsageClaudeCacheIO.cacheFileURL(
            provider: .claude, cacheRoot: env.cacheRoot, reportContext: context)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        let decoded = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot, reportContext: context)
        let rows = decoded.usage.files.keys.sorted().flatMap { decoded.usage.files[$0]?.claudeRows ?? [] }
        try self.assertShared(rows)
        #expect(try self.identities(rows.compactMap(\.messageId)).count == 10000)
        #expect(try self.identities(rows.compactMap(\.requestId)).count == 10000)
        #expect(try encoder.encode(decoded) == bytes)
        #expect(rows.map { Data(($0.sessionId ?? "").utf8) } == (0..<10000).map { Data(self.sessions[$0 % 3].utf8) })
        let unpooled = try JSONDecoder().decode(CostUsageClaudeCache.self, from: bytes)
        let unpooledRows = unpooled.usage.files.values.flatMap { $0.claudeRows ?? [] }
        #expect(try self.identities(unpooledRows.compactMap(\.sessionId)).count == 10000)
        #expect(try self.identities(unpooledRows.map(\.model)).count == 10000)
    }

    @Test
    func `transcript parse shares repeated strings without merging Unicode spellings`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 4)
        let timestamp = env.isoString(for: day)
        let lines = (0..<10000).map { index in
            """
            {"type":"assistant","timestamp":"\(timestamp)","sessionId":"\(self.sessions[index % 3])",\
            "requestId":"synthetic-request-\(index)","message":{"id":"synthetic-message-\(index)",\
            "model":"\(self.models[index % 2])","usage":{"input_tokens":1,"output_tokens":1}}}
            """
        }.joined(separator: "\n") + "\n"
        let file = try env.writeClaudeProjectFile(relativePath: "project/rows.jsonl", contents: lines)
        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: file,
            range: .init(since: day, until: day),
            providerFilter: .all,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        try self.assertShared(parsed.rows)
        #expect(parsed.parsedBytes == Int64(lines.utf8.count))
        for row in parsed.rows {
            let message = try #require(row.messageId)
            let index = try #require(Int(message.dropFirst("synthetic-message-".count)))
            #expect(Data((row.sessionId ?? "").utf8) == Data(self.sessions[index % 3].utf8))
        }
    }

    /// Independent synthesized decoder keeps required, optional and error behavior pinned to the previous schema.
    private struct SynthesizedRow: Codable {
        let d: String
        let m: String
        let s: String?
        let i: String?
        let r: String?
        let t: Int64?
        let b: Bool
        let p: CostUsageScanner.ClaudePathRole
        let `in`: Int
        let cr: Int
        let cc: Int
        let ch: Int?
        let out: Int
        let c: Int
        let priced: Bool?
        let partial: Bool?
    }

    private func decodingResult(_ type: (some Decodable).Type, bytes: Data) -> String {
        do {
            _ = try JSONDecoder().decode(type, from: bytes)
            return "success"
        } catch let DecodingError.keyNotFound(key, context) {
            return "missing:\(context.codingPath.map(\.stringValue)):\(key.stringValue)"
        } catch let DecodingError.valueNotFound(_, context) {
            return "null:\(context.codingPath.map(\.stringValue))"
        } catch let DecodingError.typeMismatch(_, context) {
            return "type:\(context.codingPath.map(\.stringValue))"
        } catch let DecodingError.dataCorrupted(context) {
            return "corrupt:\(context.codingPath.map(\.stringValue))"
        } catch {
            return "unexpected:\(error)"
        }
    }

    @Test
    func `row decoding matches synthesized schema and errors`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self.row(0))
        #expect(try encoder.encode(JSONDecoder().decode(SynthesizedRow.self, from: bytes)) == bytes)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let keys = ["d", "m", "s", "i", "r", "t", "b", "p", "in", "cr", "cc", "ch", "out", "c", "priced", "partial"]
        for key in keys {
            for replacement: Any? in [nil, NSNull(), [], "invalid"] {
                var changed = object
                changed[key] = replacement
                let data = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
                #expect(self.decodingResult(Row.self, bytes: data) == self.decodingResult(
                    SynthesizedRow.self,
                    bytes: data))
            }
        }
    }
}
