import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLISpendCapTests {
    @Test
    func `newest invalid or incomplete spend frame never falls back to stale amounts`() {
        let old = "Usage credits\n$25.00 / $100.00 spent\n"
        #expect(ClaudeCLISpendCapParser.parse(old + "Usage credits\n€40.00 / €100.00 spent") == nil)
        #expect(ClaudeCLISpendCapParser.parse(old + "Usage credits\nLoading usage") == nil)
    }

    @Test
    func `newest valid spend frame wins over an older invalid frame`() throws {
        let cost = try #require(ClaudeCLISpendCapParser.parse(
            "Usage credits\n€40.00 / €100.00 spent\nUsage credits\n$42.00 / $1,000.00 spent"))
        #expect(cost.used == 42)
        #expect(cost.limit == 1000)
        #expect(cost.currencyCode == "USD")
    }

    @Test
    func `CLI cap enrichment preserves quota and rejects an unsupported currency`() throws {
        let quota = "Current session\n12% used\nCurrent week (all models)\n25% used\n"
        let valid = try ClaudeStatusProbe.parse(text: quota + "Usage credits\n$42 / $100 spent")
        let drifted = try ClaudeStatusProbe.parse(text: quota + "Usage credits\nCA$42 / CA$100 spent")
        let usage = try ClaudeUsageFetcher.makeSnapshot(from: valid)
        #expect(usage.providerCost?.used == 42)
        #expect(usage.primary?.usedPercent == 12)
        #expect(try ClaudeUsageFetcher.makeSnapshot(from: drifted).providerCost == nil)
    }
}
