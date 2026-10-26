import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct KimiMonthlyBreakdownCLITests {
    @Test
    func `Total usage breakdown renders in CLI text and cards`() async throws {
        let snapshot = try await KimiGiftBalanceTests.fetch(api: false, stats: """
        {"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION",
          "amountUsedRatio":0.5761,"kimiCodeUsedRatio":0.0426,"expireTime":"2026-10-22T00:00:00Z"}}
        """)
        let context = RenderContext(header: "Kimi Code", status: nil, useColor: false, resetStyle: .countdown)
        let text = CLIRenderer.renderText(
            provider: .kimi, snapshot: snapshot, credits: nil, context: context, now: snapshot.updatedAt)
        let card = CLIRenderer.collectCardExtraLines(
            provider: .kimi, snapshot: snapshot, credits: nil, context: context, now: snapshot.updatedAt)

        for lines in [text.components(separatedBy: "\n"), card] {
            let code = try #require(lines.first { $0.contains("Kimi Code") && $0.contains("used") })
            #expect(code.contains("4% used"))
            let other = try #require(lines.first { $0.contains("Other features") })
            #expect(other.contains("53% used"))
        }
    }
}
