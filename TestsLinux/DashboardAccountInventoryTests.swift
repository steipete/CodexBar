import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardAccountInventoryTests {
    @Test(arguments: [DashboardIdentityMode.none, .redacted, .full])
    func `unreadable inventory warns without losing healthy accounts or disclosing diagnostics`(
        mode: DashboardIdentityMode) throws
    {
        var payload = self.payload(provider: .codex, id: "visible-profile")
        payload.dashboardAccountsIncomplete = true
        let row = try #require(self.snapshot([payload], mode: mode).providers.first)
        #expect(row.accountsError == "Account list incomplete")
        #expect(row.accounts?.count == 1)
        #expect(row.accounts?.first?.windows.first?.usedPercent == 25)
        #expect(row.error == nil)
        #expect(self.snapshot([payload], mode: mode, expanded: false).providers.first?.accountsError == nil)
        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(!json.contains("dashboardAccountsIncomplete"))
        #expect(!json.contains("Account list incomplete"))
    }

    @Test(arguments: [DashboardIdentityMode.none, .redacted, .full])
    func `missing configured account warns but an errored account still counts as collected`(
        mode: DashboardIdentityMode) throws
    {
        let first = self.payload(id: self.accountID(0))
        let failed = self.payload(id: self.accountID(1), error: "Synthetic account failure")
        let missing = try #require(self.snapshot([first], mode: mode, config: self.tokenConfig).providers.first)
        #expect(missing.accountsError == "Account list incomplete")
        #expect(missing.accounts?.first?.windows.first?.usedPercent == 25)
        #expect(missing.error == nil)
        let complete = try #require(self.snapshot([first, failed], mode: mode, config: self.tokenConfig).providers
            .first)
        #expect(complete.accountsError == nil)
        #expect(complete.accounts?.count == 2)
        #expect(complete.accounts?.last?.error != nil)
        #expect(self.snapshot([first], mode: mode, config: self.tokenConfig, expanded: false)
            .providers.first?.accountsError == nil)
    }

    @Test
    func `duplicate rows cannot hide a missing configured account`() {
        let first = self.payload(id: self.accountID(0))
        let row = self.snapshot([first, first], config: self.tokenConfig).providers.first
        #expect(row?.accountsError == "Account list incomplete")
        let complete = self.snapshot([
            first, self.payload(id: self.accountID(1)),
        ], config: self.tokenConfig).providers.first
        #expect(complete?.accountsError == nil)
    }

    @Test(arguments: [false, true], [DashboardIdentityMode.none, .redacted, .full])
    func `configured adapter remains authoritative over token inventory warnings`(
        failed: Bool, mode: DashboardIdentityMode) throws
    {
        var payload = self.payload(id: self.accountID(0))
        payload.dashboardAccountsIncomplete = true
        let adapter = DashboardClaudeSwapInput(
            accounts: failed ? nil : [],
            adapterError: failed ? "Synthetic adapter failure" : nil,
            weeklyWorkDays: nil)
        let row = try #require(self.snapshot(
            [payload], mode: mode, config: self.tokenConfig, adapter: adapter).providers.first)
        #expect(row.accountsError == (failed
                ? mode == .full ? "Synthetic adapter failure" : "Account list unavailable"
                : nil))
        if failed {
            #expect(row.accounts == nil)
        } else {
            #expect(row.accounts?.isEmpty == true)
        }
    }

    @Test(arguments: [false, true])
    func `collector preserves discovery warning in partial and completed results including ambient fallback`(
        hasVisibleAccount: Bool) async throws
    {
        let payload = self.payload(provider: .codex, id: "visible-profile")
        let account = hasVisibleAccount ? payload.dashboardAccount : nil
        let partials = DashboardInventoryPartialRecorder()
        let result = await CodexBarCLI.collectAccountUsage(
            provider: .codex,
            accounts: [account],
            inventoryIncomplete: true,
            publishPartial: { output in await partials.append(output) },
            fetch: { _ in
                var fetched = payload
                fetched.dashboardAccount = nil
                return UsageCommandOutput(payload: [fetched])
            })
        let recorded = await partials.outputs
        #expect(recorded.count == 1)
        for output in recorded + [result] {
            let row = try #require(output.payload.first)
            #expect(row.dashboardAccountsIncomplete)
            #expect((row.dashboardAccount != nil) == hasVisibleAccount)
            let provider = try #require(self.snapshot(output.payload).providers.first)
            #expect(provider.accountsError == "Account list incomplete")
        }
        #expect(result.payload.first?.usage?.primary?.usedPercent == 25)
    }

    private func accountID(_ index: Int) -> String {
        "token:00000000-0000-0000-0000-00000000000\(index + 1)"
    }

    private var tokenConfig: CodexBarConfig {
        let accounts = (0..<2).map { index in
            ProviderTokenAccount(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
                label: "Private account \(index + 1)",
                token: "synthetic",
                addedAt: 0,
                lastUsed: nil)
        }
        var provider = ProviderConfig(id: .claude, enabled: true)
        provider.tokenAccounts = ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: 0)
        return CodexBarConfig(providers: [provider])
    }

    private func snapshot(
        _ payloads: [ProviderPayload],
        mode: DashboardIdentityMode = .none,
        config: CodexBarConfig = CodexBarConfig(providers: []),
        expanded: Bool = true,
        adapter: DashboardClaudeSwapInput? = nil) -> DashboardSnapshotPayload
    {
        DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: payloads,
            costPayloads: [],
            config: config,
            identityMode: mode,
            generatedAt: Date(timeIntervalSince1970: 0),
            refreshInterval: 60,
            codexBarVersion: nil,
            claudeSwap: adapter,
            allAccounts: expanded)
    }

    private func payload(
        provider: UsageProvider = .claude,
        id: String,
        error: String? = nil) -> ProviderPayload
    {
        var payload = ProviderPayload(
            provider: provider,
            account: nil,
            version: nil,
            source: "fixture",
            status: nil,
            usage: error == nil ? UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(timeIntervalSince1970: 0)) : nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: error.map { ProviderErrorPayload(code: 1, message: $0, kind: .provider) })
        payload.dashboardAccount = DashboardUsageAccount(id: id, label: "Private account", active: false)
        return payload
    }
}

private actor DashboardInventoryPartialRecorder {
    var outputs: [UsageCommandOutput] = []

    func append(_ output: UsageCommandOutput) {
        self.outputs.append(output)
    }
}
