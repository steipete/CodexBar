import Foundation
import Testing
@testable import CodexBarCore

/// Tokscale-compatible local readers: Cursor CSV caches
/// (`~/.config/tokscale/cursor-cache/usage*.csv`) and Antigravity session caches
/// (`~/.config/tokscale/antigravity-cache/sessions/*.jsonl`).
/// Header layouts mirror `tokscale/crates/tokscale-core/src/sessions/cursor.rs`:
/// - v1: Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to
/// you
/// - v2: Date,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total
/// Tokens,Cost
/// - v3: Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache
/// Read,Output Tokens,Total Tokens,Cost
struct CursorAntigravityLocalReaderTests {
    @Test
    func `cursor v1 csv parses token buckets and cost`() throws {
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to you
        2026-08-20T10:00:00.000Z,claude-sonnet-4-5,1200,800,400,300,1500,0.012,0
        """
        let url = try Self.writeTemporary(csv, extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = CursorLocalCSVReader.parseFile(at: url)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.model == "claude-sonnet-4-5")
        #expect(row.input == 800)
        #expect(row.cacheRead == 400)
        #expect(row.cacheWrite == 400)
        #expect(row.output == 300)
        #expect(row.cost == 0.012)
    }

    @Test
    func `cursor v2 csv parses kind rows`() throws {
        let csv = [
            "Date,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),"
                + "Cache Read,Output Tokens,Total Tokens,Cost",
            "2026-08-20T11:00:00Z,chat,gpt-5.4,on,500,500,0,50,550,0.001",
        ].joined(separator: "\n") + "\n"
        let url = try Self.writeTemporary(csv, extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = CursorLocalCSVReader.parseFile(at: url)
        let row = try #require(rows.first)
        #expect(row.model == "gpt-5.4")
        #expect(row.input == 500)
        #expect(row.cacheRead == 0)
        #expect(row.cacheWrite == 0)
        #expect(row.output == 50)
    }

    @Test
    func `cursor v3 csv parses cloud agent rows`() throws {
        let csv = [
            "Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,"
                + "Input (w/ Cache Write),Input (w/o Cache Write),"
                + "Cache Read,Output Tokens,Total Tokens,Cost",
            "2026-08-20,agent-123,,agent,claude-opus-4-6,off,900,700,200,120,1020,0.05",
        ].joined(separator: "\n") + "\n"
        let url = try Self.writeTemporary(csv, extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = CursorLocalCSVReader.parseFile(at: url)
        let row = try #require(rows.first)
        #expect(row.model == "claude-opus-4-6")
        #expect(row.input == 700)
        #expect(row.cacheRead == 200)
        #expect(row.cacheWrite == 200)
        #expect(row.output == 120)
        #expect(row.cost == 0.05)
    }

    @Test
    func `cursor csv aggregation groups rows into day entries`() throws {
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to you
        2026-08-20T10:00:00.000Z,claude-sonnet-4-5,1200,800,400,300,1500,0.012,0
        2026-08-20T12:00:00.000Z,claude-sonnet-4-5,600,500,100,100,700,0.004,0
        2026-08-21T09:00:00.000Z,gpt-5.4,0,0,0,40,40,0.001,0
        """
        let url = try Self.writeTemporary(csv, extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = CursorLocalCSVReader.makeDailyReport(
            from: CursorLocalCSVReader.parseFile(at: url))
        #expect(report.data.count == 2)
        let first = try #require(report.data.first)
        #expect(first.inputTokens == 1300)
        #expect(first.cacheReadTokens == 500)
        #expect(first.cacheCreationTokens == 500)
        #expect(first.outputTokens == 400)
        #expect(first.requestCount == 2)
        #expect(first.costUSD ?? 0 == 0.016)
        let breakdowns = try #require(first.modelBreakdowns)
        #expect(breakdowns.count == 1)
        #expect(breakdowns.first?.modelName == "claude-sonnet-4-5")
        let summary = try #require(report.summary)
        // The CSV's own Total Tokens column is authoritative when present
        // (1500 + 700 + 40), rather than the recomputed bucket sum.
        #expect(summary.totalTokens == 2240)
    }

    @Test
    func `antigravity cache jsonl aggregates usage with session model fallback`() throws {
        // Derive timestamps from local noon so both events land on the same local day in any TZ.
        let calendar = Calendar.current
        let noon = calendar.date(
            byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date())) ?? Date()
        let firstStamp = Int64(noon.timeIntervalSince1970 * 1000)
        let secondStamp = firstStamp + 3_600_000
        let jsonl = [
            #"{"type":"session_meta","modelId":"test-model-a"}"#,
            #"{"type":"usage","modelId":"test-model-a","input":100,"output":30,"cacheRead":50,"cacheWrite":10,"# +
                #""timestamp":\#(firstStamp)}"#,
            #"{"type":"usage","input":40,"output":10,"cacheRead":0,"cacheWrite":0,"timestamp":\#(secondStamp)}"#,
        ].joined(separator: "\n") + "\n"
        let url = try Self.writeTemporary(jsonl, extension: "jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = AntigravityLocalReader.parseJSONLCache(paths: [url])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.inputTokens == 140)
        #expect(entry.outputTokens == 40)
        #expect(entry.cacheReadTokens == 50)
        #expect(entry.cacheCreationTokens == 10)
        #expect(entry.requestCount == 2)
        // The second event omits `modelId` and falls back to the session_meta model.
        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.map(\.modelName) == ["test-model-a"])
        #expect(breakdowns.first?.requestCount == 2)
    }

    private static func writeTemporary(_ contents: String, extension fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-antigravity-reader-\(UUID().uuidString).\(fileExtension)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
