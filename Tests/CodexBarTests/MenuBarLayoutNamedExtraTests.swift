import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MenuBarLayoutNamedExtraTests {
    @Test(arguments: [UsageProvider.codex, .claude, .gemini])
    func `weekly tokens respect provider quota cadence`(provider: UsageProvider) {
        let window = RateWindow(
            usedPercent: 25,
            windowMinutes: provider == .gemini ? 1440 : 10080,
            resetsAt: Date(),
            resetDescription: nil)
        let snapshot = UsageSnapshot(primary: nil, secondary: window, updatedAt: Date())
        let resolved = MenuBarLayoutSemanticWindowResolver.windows(provider: provider, snapshot: snapshot)
        #expect(resolved.weekly == (provider == .gemini ? nil : window))
    }

    @Test
    func `Antigravity offers both family weekly allowances independently`() throws {
        let json = antigravityQuotaSummaryJSON(
            geminiSession: 0.1, geminiWeekly: 0.8, claudeSession: 0.2, claudeWeekly: 0.6)
        let snapshot = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8)).toUsageSnapshot()
        let tokens = MenuBarLayoutNamedExtra.availableTokens(provider: .antigravity, snapshot: snapshot)
        #expect(tokens == [
            .extraPercent(id: "antigravity-quota-summary-gemini-weekly"),
            .extraPercent(id: "antigravity-quota-summary-3p-weekly"),
        ])
        #expect(tokens.map { $0.editorLabel(provider: .antigravity) } == ["Gemini weekly %", "Claude/GPT weekly %"])
        let windows = MenuBarLayoutNamedExtra.windows(provider: .antigravity, snapshot: snapshot)
        #expect(windows.map { $0.window.remainingPercent.rounded() } == [80, 60])
        #expect(windows.allSatisfy { $0.window.windowMinutes == 10080 })
        #expect(MenuBarLayoutNamedExtra.availableTokens(provider: .gemini, snapshot: snapshot).isEmpty)
        let layout = MenuBarLayout(lines: [tokens])
        #expect(try JSONDecoder().decode(MenuBarLayout.self, from: JSONEncoder().encode(layout)) == layout)
        #expect(layout.v3Compatible() == .defaultLayout)
    }

    @Test(arguments: [false, true])
    func `Antigravity weekly choices omit unknown and synthetic allowances`(synthetic: Bool) {
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: 10080,
            resetsAt: Date(),
            resetDescription: nil,
            isSyntheticPlaceholder: synthetic)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "antigravity-quota-summary-gemini-weekly",
                title: "Gemini weekly",
                window: window,
                usageKnown: synthetic)],
            updatedAt: Date())
        #expect(MenuBarLayoutNamedExtra.availableTokens(provider: .antigravity, snapshot: snapshot).isEmpty)
    }

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
