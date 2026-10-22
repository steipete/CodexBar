import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct KimiGiftBalanceCLITests {
    @Test
    func `gift balances retain expiry in CLI text and cards`() async throws {
        let snapshot = try await KimiGiftBalanceTests.fetch(api: false, stats: KimiGiftBalanceTests.stats)
        let context = RenderContext(header: "Kimi Code", status: nil, useColor: false, resetStyle: .countdown)
        let text = CLIRenderer.renderText(
            provider: .kimi, snapshot: snapshot, credits: nil, context: context, now: snapshot.updatedAt)
        let card = CLIRenderer.collectCardExtraLines(
            provider: .kimi, snapshot: snapshot, credits: nil, context: context, now: snapshot.updatedAt)

        for lines in [text.components(separatedBy: "\n"), card] {
            let gift = try #require(lines.first { $0.contains("Invite to Earn Credit") })
            #expect(gift.contains("75% left"))
            #expect(gift.contains("Expires "))
            #expect(!gift.contains("Resets"))
        }
        #expect(text.contains("Resets"))
    }
}
