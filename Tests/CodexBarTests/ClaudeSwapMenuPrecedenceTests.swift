import CodexBarCore
import Testing
@testable import CodexBar

struct ClaudeSwapMenuPrecedenceTests {
    @Test
    func `multiple Claude swap accounts take precedence`() {
        #expect(ClaudeSwapMenuPrecedence.prefersClaudeSwap(provider: .claude, accountCount: 2))
    }

    @Test
    func `precedence requires Claude and multiple swap accounts`() {
        #expect(!ClaudeSwapMenuPrecedence.prefersClaudeSwap(provider: .claude, accountCount: 0))
        #expect(!ClaudeSwapMenuPrecedence.prefersClaudeSwap(provider: .claude, accountCount: 1))
        #expect(!ClaudeSwapMenuPrecedence.prefersClaudeSwap(provider: .openai, accountCount: 2))
    }
}
