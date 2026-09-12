import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct CodexWorkspaceAuthorityPublicationTests {
    @Test
    func `personal credit dashboards preserve existing email authority`() {
        let email = "fixture@example.com"
        let decision = CodexDashboardAuthority.evaluate(CodexDashboardAuthorityInput(
            sourceKind: .cachedDashboard,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .providerAccount(id: "workspace-a"),
                expectedScopedEmail: email,
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: email,
                dashboardAccountID: "other-personal-scope",
                requiresWorkspaceBalanceScope: false,
                knownOwners: [CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "workspace-a"), normalizedEmail: email)]),
            routing: CodexDashboardRoutingHints(targetEmail: nil, lastKnownDashboardRoutingEmail: nil)))
        #expect(decision.allowedEffects.contains(.cachedDashboardReuse))
    }

    @Test(arguments: ["matching", "different", "unscoped", "stale"], [false, true])
    func `workspace authority governs app publication and CLI cache reuse`(
        scenario: String,
        unavailable: Bool) async throws
    {
        let receipt = try await CodexWorkspaceAuthorityProof.run(scenario: scenario, unavailable: unavailable)
        let expected = scenario == "matching"
        for (effect, allowed) in receipt {
            #expect(allowed == expected, "\(scenario): \(effect)")
        }
    }
}

@MainActor
enum CodexWorkspaceAuthorityProof {
    static func unscopedOAuthBalanceIsRejected() async throws -> Bool {
        let data = Data(#"{"plan_type":"business","credits":{"has_credits":true,"balance":null}}"#.utf8)
        let credentials = CodexOAuthCredentials(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            idToken: nil,
            accountId: "workspace-a",
            lastRefresh: Date())
        let original = try CodexOAuthFetchStrategy._mapResultForTesting(data, credentials: credentials)
        let browser = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .oauth,
            includeCredits: true,
            webTimeout: 10,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser)
        let result = try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
            original,
            usage: CodexOAuthUsageFetcher._decodeUsageResponseForTesting(data),
            credentials: credentials,
            context: context,
            fetcher: { _ in
                try JSONDecoder().decode(
                    CodexWorkspaceRemainingBalanceResponse.self,
                    from: Data(#"{"balance":42}"#.utf8))
            })
        return result.credits == original.credits && result.credits?.hasWorkspaceBalance != true
    }

    static func run(scenario: String, unavailable: Bool = false) async throws -> [String: Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-proof-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
            try await OpenAIDashboardCacheStore.$cacheURLOverride.withValue(root.appendingPathComponent("cache.json")) {
                try await self.exercise(scenario: scenario, unavailable: unavailable, root: root)
            }
        }
    }

    private static func exercise(scenario: String, unavailable: Bool, root: URL) async throws -> [String: Bool] {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let email = "fixture@example.com"
        let selectedID = scenario == "stale" ? "workspace-b" : "workspace-a"
        fixture.settings._test_liveSystemCodexAccount = self.account(id: "workspace-a", email: email, root: root)
        fixture.settings.codexActiveSource = .liveSystem
        fixture.settings.invalidateCodexAccountReconciliationSnapshotCache()
        let expectedGuard = fixture.store.freshCodexOpenAIWebRefreshGuard()
        if scenario == "stale" {
            fixture.settings._test_liveSystemCodexAccount = self.account(id: selectedID, email: email, root: root)
            fixture.settings.invalidateCodexAccountReconciliationSnapshotCache()
        }
        let responseID: String? = scenario == "unscoped" ? nil
            : scenario == "different" ? "workspace-b" : "workspace-a"
        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: email,
            accountID: responseID,
            codeReviewRemainingPercent: nil,
            creditEvents: [CreditEvent(date: Date(), service: "codex", creditsUsed: 1)],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: unavailable ? nil : 42,
            creditsAvailable: true,
            balanceIsWorkspace: !unavailable,
            updatedAt: Date())
        await fixture.store.applyOpenAIDashboard(dashboard, targetEmail: email, expectedGuard: expectedGuard)
        var receipt = [
            "appDashboardAttached": fixture.store.openAIDashboardAttachmentAuthorized,
            "appCreditsAttached": fixture.store.credits != nil,
            "appCacheWritten": OpenAIDashboardCacheStore.load() != nil,
        ]
        let context = try self.cliContext(root: root, id: selectedID, email: email)
        do {
            _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                dashboard: dashboard, context: context, routingTargetEmail: email)
            receipt["cliLiveAttached"] = true
        } catch is OpenAIWebCodexError {
            receipt["cliLiveAttached"] = false
        }
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(accountEmail: email, snapshot: dashboard))
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex, accountEmail: email, accountOrganization: nil, loginMethod: "fixture"))
        receipt["cliCachedReused"] = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: usage, sourceLabel: "oauth", context: context) != nil
        receipt["cliCacheRetained"] = OpenAIDashboardCacheStore.load() != nil
        return receipt
    }

    private static func account(id: String, email: String, root: URL) -> ObservedSystemCodexAccount {
        ObservedSystemCodexAccount(
            email: email, codexHomePath: root.path, observedAt: Date(), identity: .providerAccount(id: id))
    }

    private static func cliContext(root: URL, id: String, email: String) throws -> ProviderFetchContext {
        let claims: [String: Any] = ["email": email, "https://api.openai.com/auth": ["chatgpt_account_id": id]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let auth = ["tokens": [
            "accessToken": "fixture-access",
            "refreshToken": "fixture-refresh",
            "idToken": "e30.\(payload).",
            "accountId": id,
        ]]
        try JSONSerialization.data(withJSONObject: auth).write(to: root.appendingPathComponent("auth.json"))
        let env = ["CODEX_HOME": root.path]
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: true,
            webTimeout: 10,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(codex: .init(
                usageDataSource: .auto,
                cookieSource: .auto,
                manualCookieHeader: nil,
                dashboardAuthorityKnownOwners: [CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: id), normalizedEmail: email)])),
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser)
    }
}
