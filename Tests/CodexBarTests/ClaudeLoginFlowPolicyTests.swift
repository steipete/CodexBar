import CodexBarCore
import Testing
@testable import CodexBar

struct ClaudeLoginFlowPolicyTests {
    @Test
    func `successful Claude login keeps source on auto so fallback remains available`() {
        for source in ClaudeUsageDataSource.allCases {
            #expect(ClaudeLoginFlowPolicy.usageDataSourceAfterSuccessfulLogin(previous: source) == .auto)
        }
    }
}
