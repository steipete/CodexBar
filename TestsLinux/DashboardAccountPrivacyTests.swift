import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardAccountPrivacyTests {
    @Test(arguments: [false, true])
    func `expanded defaults never inherit the app identity preference`(hidePersonalInfo: Bool) {
        #expect(CodexBarCLI.resolveDashboardIdentityMode(
            configured: nil, hidesPersonalInfo: hidePersonalInfo, allAccounts: true) == .none)
        for explicit in [DashboardIdentityMode.full, .redacted] {
            #expect(CodexBarCLI.resolveDashboardIdentityMode(
                configured: explicit, hidesPersonalInfo: hidePersonalInfo, allAccounts: true) == explicit)
        }
        #expect(CodexBarCLI.resolveDashboardIdentityMode(
            configured: nil, hidesPersonalInfo: hidePersonalInfo) == (hidePersonalInfo ? .redacted : .full))
    }

    @Test(arguments: [DashboardIdentityMode.none, .redacted, .full])
    func `account labels and errors require full identity while usage remains available`(
        mode: DashboardIdentityMode) async throws
    {
        var healthy = self.payload(error: nil)
        healthy.dashboardAccount = DashboardUsageAccount(id: "opaque-1", label: "Private Team", active: false)
        var failed = self.payload(error: "Expired for Private Team: person@example.test at /home/private")
        failed.dashboardAccount = DashboardUsageAccount(id: "opaque-2", label: "Secret Client", active: true)
        let producer = self.producer([healthy, failed])
        // Omit the identity argument to exercise the producer's defensive private default too.
        let result = try await producer.collect(
            config: self.config,
            refreshInterval: 60,
            codexBarVersion: nil,
            identityMode: mode == .none ? nil : mode)
        let row = try #require(result.payload.providers.first)
        let accounts = try #require(row.accounts)
        #expect(accounts.map(\.label) == (mode == .full ? ["Private Team", "Secret Client"] : [
            "Account 1",
            "Account 2",
        ]))
        #expect(accounts.map(\.active) == [false, true])
        #expect(accounts[0].windows.first?.usedPercent == 25)
        #expect(accounts[1].windows.isEmpty)
        #expect(row.windows.isEmpty)
        #expect(row.error?.message == accounts[1].error)
        #expect(accounts[0].identity?.accountEmail == (mode == .none ? nil : mode == .full
                ? "person@example.test" : "redacted@example.test"))
        let json = try #require(String(data: JSONEncoder().encode(result.payload), encoding: .utf8))
        if mode != .full {
            for secret in ["Private Team", "Secret Client", "person@example.test", "/home/private"] {
                #expect(!json.contains(secret))
            }
            #expect(accounts[1].error == "Account usage unavailable")
        } else {
            #expect(json.contains("Private Team"))
            #expect(json.contains("person@example.test"))
        }
    }

    @Test(arguments: [DashboardIdentityMode.none, .redacted, .full], [false, true])
    func `configured adapter failure omits accounts even with token account fallback available`(
        mode: DashboardIdentityMode, expanded: Bool) async throws
    {
        let diagnostic = "Private Team at /home/private: person@example.test"
        var producer = self.producer([self.payload(error: nil)], expanded: expanded)
        producer.collectClaudeSwapAccounts = { _ in
            DashboardClaudeSwapCollection(accounts: nil, adapterError: diagnostic)
        }
        let result = try await producer.collect(
            config: self.config, refreshInterval: 60, codexBarVersion: nil, identityMode: mode)
        let row = try #require(result.payload.providers.first)
        #expect(row.accounts == nil)
        #expect(row.accountsError == (expanded && mode != .full ? "Account list unavailable" : diagnostic))
        #expect(row.windows.first?.usedPercent == 25)
        let data = try JSONEncoder().encode(result.payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        #expect(providers[0]["accounts"] == nil)
        if expanded, mode != .full {
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(!json.contains("Private Team"))
            #expect(!json.contains("person@example.test"))
            #expect(!json.contains("/home/private"))
        }
    }

    @Test(arguments: [DashboardIdentityMode.none, .redacted, .full])
    func `adapter aliases and errors are private and successful empty results stay authoritative`(
        mode: DashboardIdentityMode) async throws
    {
        let account = ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "7"),
            provider: .claude,
            displayLabel: "Private Team",
            accountEmail: "person@example.test",
            isActive: true,
            snapshot: nil,
            error: "Private Team expired",
            sourceLabel: nil)
        for rows in [[account], []] {
            var producer = self.producer([self.payload(error: nil)])
            producer.collectClaudeSwapAccounts = { _ in
                DashboardClaudeSwapCollection(accounts: rows, adapterError: nil)
            }
            let result = try await producer.collect(
                config: self.config, refreshInterval: 60, codexBarVersion: nil, identityMode: mode)
            let provider = try #require(result.payload.providers.first)
            let accounts = try #require(provider.accounts)
            #expect(accounts.count == rows.count)
            #expect(provider.accountsError == nil)
            if let first = accounts.first {
                #expect(first.id == "claude-swap:7")
                #expect(first.label == (mode == .full ? "Private Team" : "Account 1"))
                #expect(first.error == (mode == .full ? "Private Team expired" : "Account usage unavailable"))
                #expect(first.identity?.accountEmail == (mode == .none ? nil : mode == .full
                        ? "person@example.test" : "redacted@example.test"))
            }
        }
    }

    @Test
    func `warm response cache never replays full identities in private mode`() async throws {
        let cache = CLIServeResponseCache()
        for mode in [DashboardIdentityMode.full, .none, .redacted, .none] {
            let key = try CodexBarCLI.serveDashboardOperationKey(
                identityMode: mode, usageBarsShowUsed: false, provider: "claude", allAccounts: true)
            let expected = Data(mode.rawValue.utf8)
            let response = await CodexBarCLI.cachedServeResponse(
                key: key, cache: cache, refreshInterval: 60, configFingerprint: "fixture")
            { CLILocalHTTPResponse(status: .ok, body: expected) }
            #expect(response.body == expected)
        }
        #expect(await cache.cachedEntryCount() == 3)
    }

    private var config: CodexBarConfig {
        CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)])
    }

    private func producer(_ payloads: [ProviderPayload], expanded: Bool = true) -> DashboardSnapshotProducer {
        DashboardSnapshotProducer(
            collectUsage: { _ in UsageCommandOutput(payload: payloads) },
            collectCost: { _, _ in [] },
            now: { Date(timeIntervalSince1970: 0) },
            allAccounts: expanded)
    }

    private func payload(error: String?) -> ProviderPayload {
        var payload = ProviderPayload(
            provider: .claude,
            account: nil,
            version: nil,
            source: "fixture",
            status: nil,
            usage: error == nil ? UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                identity: ProviderIdentitySnapshot(
                    providerID: UsageProvider.claude.instanceID,
                    accountEmail: "person@example.test",
                    accountOrganization: "Private Team",
                    loginMethod: "pro")) : nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: error.map { ProviderErrorPayload(code: 1, message: $0, kind: .provider) })
        payload.dashboardAccount = DashboardUsageAccount(id: "opaque", label: "Private Team", active: true)
        return payload
    }
}
