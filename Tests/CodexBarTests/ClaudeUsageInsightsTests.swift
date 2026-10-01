import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeUsageInsightsTests {
    private let insights = """
    What's contributing to your limits usage?
    Approximate, based on local sessions on this machine — does not include other devices or claude.ai.
    Last 24h · 100 requests · 2 sessions
      30% of your usage was at >150k context
      20% of your usage was while 4+ sessions ran in parallel
      Top MCP servers: Claude Browser 10%, claude-in-chrome 5%
    Last 7d · 1000 requests · 20 sessions
      Top skills: Claude Max 20%
    """

    @Test
    func `quota panel ignores user named insights when extracting identity`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: """
        Settings Status Config Usage Stats
        Current session
        ██████ 13% used
        Resets 2:20pm (Asia/Singapore)
        Current week (all models)
        █ 2% used
        Resets Oct 3 at 8am (Asia/Singapore)
        \(self.insights)
        """)
        #expect(snapshot.sessionPercentLeft == 87)
        #expect(snapshot.weeklyPercentLeft == 98)
        #expect(snapshot.loginMethod == nil)
        #expect(snapshot.primaryResetDescription == "Resets 2:20pm (Asia/Singapore)")
    }

    @Test
    func `insights without quotas never become numeric limits`() {
        #expect(throws: ClaudeStatusProbeError.self) {
            try ClaudeStatusProbe.parse(text: """
            You are currently using your subscription to power your Claude Code usage
            \(self.insights)
            """)
        }
    }
}
