import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct TokenAccountCLISelectionTests {
    @Test
    func `usage and cards share provider selection constraints`() {
        let all = TokenAccountCLISelection(label: nil, index: nil, allAccounts: true)
        #expect(all.providerSelectionError([.codex]) == nil)
        #expect(all.providerSelectionError([.claude]) == nil)
        #expect(all.providerSelectionError([.codex, .claude]) == "account selection requires a single provider.")
        #expect(all.providerSelectionError([]) == "account selection requires a single provider.")
        #expect(all.providerSelectionError([.jetbrains]) == "jetbrains does not support token accounts.")
        let automatic = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        #expect(automatic.providerSelectionError([.jetbrains, .claude]) == nil)
    }
}
