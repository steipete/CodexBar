import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MenuBarLayoutNamedExtraTests {
    @Test
    func `saved Grok Bot selection decodes without losing reset choices`() throws {
        let json = """
        {"lines":[[{"icon":{}},{"windowResetCountdown":{"window":"weekly"}},
        {"extraPercent":{"id":"cursor-grok-bot"}}]]}
        """
        let layout = try JSONDecoder().decode(MenuBarLayout.self, from: Data(json.utf8))
        #expect(layout.lines[0].count == 3)
        #expect(layout.lines[0][1] == .windowResetCountdown(window: .weekly))
        #expect(layout.lines[0][2].editorLabel(provider: .cursor) == "Grok Bot %")
    }

    @Test(arguments: [false, true])
    func `palette follows the card allowance filter`(hasLimit: Bool) {
        let status = CursorSandUsageStatus(
            currentPeriodStart: nil,
            nextResetTimestampUtc: nil,
            usagePercent: 42,
            hasAvailableUsage: false,
            hasNonZeroIncludedLimit: hasLimit)
        let extra = status.extraRateWindow(resetDescription: { _ in "Reset" })
        let snapshot = UsageSnapshot(
            primary: nil, secondary: nil, extraRateWindows: extra.map { [$0] }, updatedAt: Date())
        #expect(MenuBarLayoutNamedExtra.availableTokens(provider: .cursor, snapshot: snapshot).isEmpty == !hasLimit)
    }

    @Test
    func `extra refresh signature tracks placed windows and ignores unrelated usage`() {
        let tokens = [MenuBarLayoutToken.extraPercent(id: "cursor-grok-bot")]
        let first = self.snapshot(used: 42)
        let changed = self.snapshot(used: 43)
        let signature = MenuBarLayoutRenderExtra.signature(tokens: tokens, provider: .cursor, snapshot: first)
        #expect(signature != MenuBarLayoutRenderExtra.signature(tokens: tokens, provider: .cursor, snapshot: changed))
        #expect(signature != MenuBarLayoutRenderExtra.signature(tokens: tokens, provider: .cursor, snapshot: nil))
        #expect(signature == MenuBarLayoutRenderExtra.signature(
            tokens: tokens, provider: .cursor, snapshot: self.snapshot(used: 42, primaryUsed: 99)))
        #expect(MenuBarLayoutRenderExtra.signature(tokens: [.icon], provider: .cursor, snapshot: first) == nil)
    }

    @Test
    func `unknown and synthetic named usage is unavailable`() {
        for extra in [
            NamedRateWindow(
                id: "cursor-grok-bot",
                title: "Grok Bot",
                window: RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: true)),
            NamedRateWindow(
                id: "cursor-grok-bot",
                title: "Grok Bot",
                window: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                usageKnown: false),
        ] {
            let snapshot = UsageSnapshot(primary: nil, secondary: nil, extraRateWindows: [extra], updatedAt: Date())
            #expect(MenuBarLayoutNamedExtra.availableTokens(provider: .cursor, snapshot: snapshot).isEmpty)
            #expect(MenuBarLayoutRenderExtra(extra).window == nil)
        }
    }

    private func snapshot(used: Double, primaryUsed: Double = 10) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: primaryUsed, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "cursor-grok-bot",
                title: "Grok Bot",
                window: RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: nil, resetDescription: nil))],
            updatedAt: Date(timeIntervalSince1970: 100))
    }
}
