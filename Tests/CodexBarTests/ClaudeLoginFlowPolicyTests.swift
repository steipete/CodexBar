import CodexBarCore
import Testing
@testable import CodexBar

struct ClaudeLoginFlowPolicyTests {
    @Test
    func `successful Claude login preserves selected source so auto fallback remains available`() {
        for source in ClaudeUsageDataSource.allCases {
            #expect(ClaudeLoginFlowPolicy.usageDataSourceAfterSuccessfulLogin(previous: source) == source)
        }
    }
}
