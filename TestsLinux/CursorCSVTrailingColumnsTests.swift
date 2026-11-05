import Foundation
import Testing
@testable import CodexBarCore

struct CursorCSVTrailingColumnsTests {
    @Test(arguments: [false, true])
    func `Cursor v2 CSV retains usage with a trailing customer cost column`(customerCost: Bool) throws {
        try Self.checkCSV(
            header: "Date,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),"
                + "Cache Read,Output Tokens,Total Tokens,Cost",
            row: "2026-10-30T12:00:00Z,chat,gpt-5.4,on,900,700,200,120,1020,0.05",
            customerCost: customerCost)
    }

    @Test(arguments: [false, true])
    func `Cursor cloud agent CSV retains usage with a trailing customer cost column`(customerCost: Bool) throws {
        try Self.checkCSV(
            header: "Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,"
                + "Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost",
            row: "2026-10-30T12:00:00Z,agent-example,,agent,gpt-5.4,on,900,700,200,120,1020,0.05",
            customerCost: customerCost)
    }

    private static func checkCSV(header: String, row: String, customerCost: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.csv")
        let csv = header + (customerCost ? ",Cost to you" : "") + "\n"
            + row + (customerCost ? ",0" : "") + "\n"
        try csv.write(to: url, atomically: true, encoding: .utf8)

        let rows = CursorLocalCSVReader.parseFile(at: url)
        #expect(rows.count == 1)
        let parsed = try #require(rows.first)
        #expect(parsed.model == "gpt-5.4")
        #expect(parsed.input == 700)
        #expect(parsed.cacheRead == 200)
        #expect(parsed.cacheWrite == 200)
        #expect(parsed.output == 120)
        #expect(parsed.totalTokens == 1020)
        #expect(parsed.cost == 0.05)
        let report = CursorLocalCSVReader.makeDailyReport(from: rows)
        #expect(report.summary?.totalTokens == 1020)
        #expect(report.summary?.totalCostUSD == 0.05)
    }
}
