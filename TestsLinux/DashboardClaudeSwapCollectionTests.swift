import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct DashboardClaudeSwapCollectionTests {
    @Test(arguments: [false, true], [false, true])
    func `serving queries only selected Claude credentials when the account adapter is authoritative`(
        adapterEnabled: Bool, expanded: Bool) async throws
    {
        let accounts = self.accounts
        let config = self.config(adapterEnabled: adapterEnabled)
        let calls = ClaudeDashboardFetchRecorder()
        let operations = CLIServeOperationCoordinator<UsageCommandOutput>()
        let context = ServeUsageContext(
            config: config,
            configFingerprint: "fixture-\(adapterEnabled)-\(expanded)",
            refreshInterval: 0,
            providerTimeout: 10,
            providerDeadline: .now.advanced(by: .seconds(10)),
            providerOperations: operations,
            includeAllCodexAccounts: expanded,
            includeAllAccounts: expanded,
            persistCLISessions: false)
        let usage = try JSONDecoder().decode(
            OAuthUsageResponse.self, from: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
        let output = try await CodexBarCLI.serveUsageOutput(
            selection: .custom([.claude]),
            context: context,
            fetchUsage: { provider, tokenContext, command, publish in
                let loadCredentials: @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials =
                    { environment, _, _ in
                        let token = try #require(environment[ClaudeOAuthCredentialsStore.environmentTokenKey])
                        return ClaudeOAuthCredentials(
                            accessToken: token,
                            refreshToken: nil,
                            expiresAt: Date().addingTimeInterval(3600),
                            scopes: ["user:profile"],
                            rateLimitTier: "claude_pro")
                    }
                let fetchUsage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { token, _ in
                    let account = try #require(accounts.first { $0.token == token })
                    await calls.append(account.id)
                    return usage
                }
                let fetchProfile: @Sendable (String) async throws -> OAuthProfileResponse = { _ in
                    OAuthProfileResponse(
                        emailAddress: "fixture@example.test",
                        organizationUuid: "fixture-org",
                        accountUuid: "fixture-account")
                }
                // Install hooks inside the detached worker; all credential and HTTP access stays synthetic.
                return await ClaudeUsageFetcher.$hasCachedCredentialsOverride.withValue(true) {
                    await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredentials) {
                        await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchUsage) {
                            await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue(fetchProfile) {
                                await CodexBarCLI.fetchUsageOutputs(
                                    provider: provider,
                                    status: nil,
                                    tokenContext: tokenContext,
                                    command: command,
                                    publishPartial: publish)
                            }
                        }
                    }
                }
            })
        let expected = expanded && !adapterEnabled ? accounts : [accounts[1]]
        let queriedAccounts = await calls.accountIDs
        #expect(queriedAccounts == expected.map(\.id))
        #expect(output.payload.count == expected.count)
        #expect(output.payload.map { $0.dashboardAccount?.id } == expected.map {
            DashboardUsageAccount.token($0, active: $0.id == accounts[1].id).id
        })
        #expect(output.payload.allSatisfy { $0.error == nil && $0.usage?.primary?.usedPercent == 25 })
        #expect(output.payload.last?.dashboardAccount?.active == true)
        #expect(await operations.snapshot().operationCount == 0)
    }

    @Test
    func `adapter preference does not suppress other providers or disabled adapter configurations`() {
        let configured = self.config(adapterEnabled: true)
        #expect(!CodexBarCLI.serveIncludesConfiguredAccounts(provider: .claude, config: configured, allAccounts: true))
        #expect(CodexBarCLI.serveIncludesConfiguredAccounts(provider: .ibmbob, config: configured, allAccounts: true))
        var disabled = configured
        disabled.providers[0].enabled = false
        #expect(CodexBarCLI.serveIncludesConfiguredAccounts(provider: .claude, config: disabled, allAccounts: true))
    }

    private var accounts: [ProviderTokenAccount] {
        (0..<2).map { index in
            ProviderTokenAccount(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
                label: "Fixture \(index + 1)",
                token: "sk-ant-oat01-synthetic-fixture-\(index + 1)",
                addedAt: 0,
                lastUsed: nil)
        }
    }

    private func config(adapterEnabled: Bool) -> CodexBarConfig {
        let data = ProviderTokenAccountData(version: 1, accounts: self.accounts, activeIndex: 1)
        var claude = ProviderConfig(id: .claude, enabled: true, tokenAccounts: data)
        claude.source = .oauth
        claude.claudeSwapEnabled = adapterEnabled
        return CodexBarConfig(providers: [claude, ProviderConfig(id: .ibmbob, enabled: true, tokenAccounts: data)])
    }
}

private actor ClaudeDashboardFetchRecorder {
    var accountIDs: [UUID] = []

    func append(_ accountID: UUID) {
        self.accountIDs.append(accountID)
    }
}
