import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeUsageCacheIsolationTests {
    @Test
    func `raw usage selects configured Claude accounts with dashboard swap enabled`() async throws {
        var claude = ProviderConfig(
            id: .claude,
            enabled: true,
            tokenAccounts: ProviderTokenAccountData(
                version: 1,
                accounts: [
                    ProviderTokenAccount(id: UUID(), label: "One", token: "synthetic-one", addedAt: 1, lastUsed: nil),
                    ProviderTokenAccount(id: UUID(), label: "Two", token: "synthetic-two", addedAt: 1, lastUsed: nil),
                ],
                activeIndex: 0))
        claude.claudeSwapEnabled = true
        let selections = LockIsolated<[Bool]>([])
        let context = ServeUsageContext(
            config: CodexBarConfig(providers: [claude]),
            configFingerprint: "synthetic",
            refreshInterval: 60,
            providerTimeout: nil,
            providerDeadline: nil,
            providerOperations: CLIServeOperationCoordinator(),
            includeAllAccounts: true,
            persistCLISessions: false)
        let fetch: CodexBarCLI.ServeUsageFetcher = { _, tokenContext, _, _ in
            selections.setValue(selections.value + [tokenContext.selection.allAccounts])
            return UsageCommandOutput()
        }

        _ = try await CodexBarCLI.serveUsageOutput(selection: .custom([.claude]), context: context, fetchUsage: fetch)
        #expect(selections.value == [true])
        _ = try await CodexBarCLI.serveUsageOutput(
            selection: .custom([.claude]), context: context, collectsDashboardAccounts: true, fetchUsage: fetch)
        #expect(selections.value == [true, false])
        #expect(CodexBarCLI.serveUsageOperationFingerprint(
            configFingerprint: "synthetic", includeAllCodexAccounts: true, includeAllAccounts: true)
            != CodexBarCLI.serveUsageOperationFingerprint(
                configFingerprint: "synthetic",
                includeAllCodexAccounts: true,
                includeAllAccounts: true,
                usesClaudeSwap: true))
    }

    @Test
    func `usage route keeps single and all account responses separate`() async throws {
        let store = testConfigStore(suiteName: "CLIServeUsageCacheIsolationTests-\(UUID().uuidString)")
        defer { try? store.deleteIfPresent() }
        try store.save(CodexBarConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: false)
        }))
        let snapshot = try CodexBarCLI.loadServeConfigSnapshot(configStore: store)
        let cache = CLIServeResponseCache()
        let operation = try CodexBarCLI.serveOperationKey(kind: "usage", provider: nil)
        for (suffix, count) in [("", 1), (":all-accounts", 2)] {
            let body = try JSONSerialization.data(withJSONObject: (0..<count).map {
                ["provider": "claude", "account": "synthetic-\($0)", "source": "synthetic"]
            })
            _ = await cache.completeFetch(
                CLILocalHTTPResponse(status: .ok, body: body),
                for: CodexBarCLI.serveCacheKey(operationKey: operation + suffix, configToken: snapshot.cacheToken),
                policy: .init(ttl: 60, staleTTL: 600),
                now: Date(),
                shouldCache: true)
        }
        let runtime = ServeRuntime(
            configStore: store,
            cache: cache,
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 5,
            healthVersion: "0.0.0-test",
            dashboardAuth: CLIServeDashboardAuth(bearer: nil),
            bindHost: "127.0.0.1")
        for (value, expectedCount) in [("true", 2), ("false", 1), ("yes", 2), ("1", 2), ("", 1)] {
            let response = await CodexBarCLI.handleServeRequest(CLILocalHTTPRequest(
                method: "GET",
                target: "/usage",
                host: "127.0.0.1",
                path: "/usage",
                queryItems: ["allAccounts": value],
                authorization: nil), runtime: runtime)
            let rows = try #require(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
            #expect(response.status == .ok)
            #expect(rows.count == expectedCount)
        }
    }
}
