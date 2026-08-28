import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct AppAutoVerifierAccountScopeTests {
    @Test
    func `ambient account scope ignores configured Claude token accounts`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Configured",
                    token: "Bearer sk-ant-oat-account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = CodexBarConfig(
            providers: [ProviderConfig(id: .claude, tokenAccounts: accounts)])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            resolutionScope: .ambientAccount)

        #expect(try tokenContext.resolvedAccounts(for: .claude).isEmpty)
        #expect(tokenContext.effectiveSourceMode(base: .cli, provider: .claude, account: nil) == .cli)
        #expect(tokenContext.effectiveSourceMode(base: .auto, provider: .claude, account: nil) == .auto)
    }
}
