import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct CostHistoryChartMenuViewTests {
    @Test
    func `codex cost history chart labels local machine scope`() {
        #expect(CostHistoryChartMenuView.scopeNote(provider: .codex) ==
            "Local Codex logs on this Mac; remote usage may be missing.")
    }

    @Test
    func `non codex cost history chart does not add account scope warning`() {
        #expect(CostHistoryChartMenuView.scopeNote(provider: .claude) == nil)
    }
}
