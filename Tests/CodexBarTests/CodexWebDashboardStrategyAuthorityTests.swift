import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct CodexWebDashboardStrategyAuthorityTests {
    @Test
    func `web dashboard attach converts snapshot with authority attachment email`() throws {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let authHome = try self.makeAuthHome(
            email: "owner@example.com",
            accountId: "acct-owner")
        defer { try? FileManager.default.removeItem(at: authHome) }

        let context = self.makeContext(
            authHome: authHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-owner"),
                    normalizedEmail: "owner@example.com"),
            ])
        let result = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
            dashboard: self.makeDashboard(email: "owner@example.com"),
            context: context,
            routingTargetEmail: "route@example.com")

        #expect(result.usage.accountEmail(for: .codex) == "owner@example.com")
        #expect(result.credits?.remaining == 42)
    }

    @Test
    func `web dashboard display only throws typed policy error`() throws {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let authHome = try self.makeAuthHome(email: "shared@example.com")
        defer { try? FileManager.default.removeItem(at: authHome) }

        let context = self.makeContext(
            authHome: authHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-alpha"),
                    normalizedEmail: "shared@example.com"),
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-beta"),
                    normalizedEmail: "shared@example.com"),
            ])
        let dashboard = self.makeDashboard(email: "shared@example.com")
        let expectedDecision = CodexDashboardAuthority.evaluate(
            CodexCLIDashboardAuthorityContext.makeLiveWebInput(
                dashboard: dashboard,
                context: context,
                routingTargetEmail: "route@example.com"))

        do {
            _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                dashboard: dashboard,
                context: context,
                routingTargetEmail: "route@example.com")
            Issue.record("Expected CodexDashboardPolicyError.displayOnly")
        } catch let error as CodexDashboardPolicyError {
            #expect(error == .displayOnly(expectedDecision))
        } catch {
            Issue.record("Expected CodexDashboardPolicyError.displayOnly, got \(error)")
        }
    }

    @Test
    func `web dashboard fail closed throws policy rejection`() throws {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let authHome = try self.makeAuthHome(
            email: "owner@example.com",
            accountId: "acct-owner")
        defer { try? FileManager.default.removeItem(at: authHome) }

        let context = self.makeContext(
            authHome: authHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-other"),
                    normalizedEmail: "owner@example.com"),
            ])
        let dashboard = self.makeDashboard(email: "owner@example.com")
        let expectedDecision = CodexDashboardAuthority.evaluate(
            CodexCLIDashboardAuthorityContext.makeLiveWebInput(
                dashboard: dashboard,
                context: context,
                routingTargetEmail: "route@example.com"))

        do {
            _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                dashboard: dashboard,
                context: context,
                routingTargetEmail: "route@example.com")
            Issue.record("Expected OpenAIWebCodexError.policyRejected")
        } catch let error as OpenAIWebCodexError {
            #expect(error == .policyRejected(expectedDecision))
        } catch {
            Issue.record("Expected OpenAIWebCodexError.policyRejected, got \(error)")
        }
    }

    @Test
    func `web dashboard wrong email throws policy rejection`() throws {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let authHome = try self.makeAuthHome(
            email: "owner@example.com",
            accountId: "acct-owner")
        defer { try? FileManager.default.removeItem(at: authHome) }

        let context = self.makeContext(
            authHome: authHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-owner"),
                    normalizedEmail: "owner@example.com"),
            ])
        let dashboard = self.makeDashboard(email: "other@example.com")
        let expectedDecision = CodexDashboardAuthority.evaluate(
            CodexCLIDashboardAuthorityContext.makeLiveWebInput(
                dashboard: dashboard,
                context: context,
                routingTargetEmail: "owner@example.com"))

        do {
            _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                dashboard: dashboard,
                context: context,
                routingTargetEmail: "owner@example.com")
            Issue.record("Expected OpenAIWebCodexError.policyRejected")
        } catch let error as OpenAIWebCodexError {
            #expect(error == .policyRejected(expectedDecision))
            if case let .policyRejected(decision) = error {
                #expect(decision.reason == .wrongEmail(expected: "owner@example.com", actual: "other@example.com"))
            }
        } catch {
            Issue.record("Expected OpenAIWebCodexError.policyRejected, got \(error)")
        }
    }

    @Test
    func `web dashboard provider account without scoped auth email fail closes on dashboard collision`() throws {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let authHome = try self.makeAuthHome(email: nil, accountId: "acct-owner")
        defer { try? FileManager.default.removeItem(at: authHome) }

        let context = self.makeContext(
            authHome: authHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-alpha"),
                    normalizedEmail: "shared@example.com"),
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-beta"),
                    normalizedEmail: "shared@example.com"),
            ])
        let dashboard = self.makeDashboard(email: "shared@example.com")
        let expectedDecision = CodexDashboardAuthority.evaluate(
            CodexCLIDashboardAuthorityContext.makeLiveWebInput(
                dashboard: dashboard,
                context: context,
                routingTargetEmail: "shared@example.com"))

        do {
            _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                dashboard: dashboard,
                context: context,
                routingTargetEmail: "shared@example.com")
            Issue.record("Expected OpenAIWebCodexError.policyRejected")
        } catch let error as OpenAIWebCodexError {
            #expect(error == .policyRejected(expectedDecision))
            if case let .policyRejected(decision) = error {
                #expect(decision.reason == .providerAccountMissingScopedEmail)
            }
        } catch {
            Issue.record("Expected OpenAIWebCodexError.policyRejected, got \(error)")
        }
    }

    @Test
    func `web dashboard attach saves cache with attached email not routing fallback`() throws {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let authHome = try self.makeAuthHome(
            email: "owner@example.com",
            accountId: "acct-owner")
        defer { try? FileManager.default.removeItem(at: authHome) }

        let context = self.makeContext(
            authHome: authHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-owner"),
                    normalizedEmail: "owner@example.com"),
            ])

        _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
            dashboard: self.makeDashboard(email: "owner@example.com"),
            context: context,
            routingTargetEmail: "route@example.com")

        let cache = try #require(OpenAIDashboardCacheStore.load())
        #expect(cache.accountEmail == "owner@example.com")
        #expect(cache.accountEmail != "route@example.com")
    }

    @Test
    func `web dashboard fail closed clears stale cache`() throws {
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "stale@example.com",
            snapshot: self.makeDashboard(email: "stale@example.com")))
        defer { OpenAIDashboardCacheStore.clear() }

        let authHome = try self.makeAuthHome(
            email: "owner@example.com",
            accountId: "acct-owner")
        defer { try? FileManager.default.removeItem(at: authHome) }

        let context = self.makeContext(
            authHome: authHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-other"),
                    normalizedEmail: "owner@example.com"),
            ])

        do {
            _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                dashboard: self.makeDashboard(email: "owner@example.com"),
                context: context,
                routingTargetEmail: "route@example.com")
            Issue.record("Expected OpenAIWebCodexError.policyRejected")
        } catch is OpenAIWebCodexError {}

        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    @Test
    func `web dashboard display only clears stale cache`() throws {
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "stale@example.com",
            snapshot: self.makeDashboard(email: "stale@example.com")))
        defer { OpenAIDashboardCacheStore.clear() }

        let authHome = try self.makeAuthHome(email: "shared@example.com")
        defer { try? FileManager.default.removeItem(at: authHome) }

        let context = self.makeContext(
            authHome: authHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-alpha"),
                    normalizedEmail: "shared@example.com"),
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-beta"),
                    normalizedEmail: "shared@example.com"),
            ])

        do {
            _ = try CodexWebDashboardStrategy.makeAuthorizedDashboardResultForTesting(
                dashboard: self.makeDashboard(email: "shared@example.com"),
                context: context,
                routingTargetEmail: "route@example.com")
            Issue.record("Expected CodexDashboardPolicyError.displayOnly")
        } catch is CodexDashboardPolicyError {}

        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    private func makeContext(
        authHome: URL? = nil,
        knownOwners: [CodexDashboardKnownOwnerCandidate]) -> ProviderFetchContext
    {
        let env = authHome.map { ["CODEX_HOME": $0.path] } ?? [:]
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(
                codex: .init(
                    usageDataSource: .auto,
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                    dashboardAuthorityKnownOwners: knownOwners)),
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func makeDashboard(email: String) -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: 75,
            codeReviewLimit: RateWindow(
                usedPercent: 25,
                windowMinutes: 60,
                resetsAt: Date(timeIntervalSince1970: 3600),
                resetDescription: nil),
            creditEvents: [
                CreditEvent(
                    date: Date(timeIntervalSince1970: 1000),
                    service: "codex",
                    creditsUsed: 3),
            ],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 7200),
                resetDescription: nil),
            secondaryLimit: nil,
            creditsRemaining: 42,
            accountPlan: "pro",
            updatedAt: Date(timeIntervalSince1970: 2000))
    }

    private func makeAuthHome(email: String?, accountId: String? = nil) throws -> URL {
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try self.writeCodexAuthFile(homeURL: homeURL, email: email, accountId: accountId)
        return homeURL
    }

    private func writeCodexAuthFile(
        homeURL: URL,
        email: String?,
        accountId: String?) throws
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, accountId: accountId),
        ]
        if let accountId {
            tokens["accountId"] = accountId
        }
        let auth = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String?, accountId: String?) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var authClaims: [String: Any] = [
            "chatgpt_plan_type": "pro",
        ]
        if let accountId {
            authClaims["chatgpt_account_id"] = accountId
        }
        var claims: [String: Any] = [
            "chatgpt_plan_type": "pro",
            "https://api.openai.com/auth": authClaims,
        ]
        if let email {
            claims["email"] = email
        }
        let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}
