import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct CLIOpenAIDashboardCacheTests {
    @Test
    func `cached dashboard restores when authority allows cached reuse`() throws {
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
        let dashboard = self.makeDashboard(email: "owner@example.com")
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "stale-route@example.com",
            snapshot: dashboard))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: nil),
            sourceLabel: "openai-web",
            context: context)

        #expect(restored == dashboard)
    }

    @Test
    func `cached dashboard returns nil on display only and clears cache`() throws {
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
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "shared@example.com",
            snapshot: self.makeDashboard(email: "shared@example.com")))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "shared@example.com"),
            sourceLabel: "codex-cli",
            context: context)

        #expect(restored == nil)
        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    @Test
    func `cached dashboard returns nil on fail closed and clears cache`() throws {
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
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "owner@example.com",
            snapshot: self.makeDashboard(email: "owner@example.com")))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "owner@example.com"),
            sourceLabel: "codex-cli",
            context: context)

        #expect(restored == nil)
        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    @Test
    func `cached dashboard wrong email returns nil and clears cache`() throws {
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
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "other@example.com",
            snapshot: self.makeDashboard(email: "other@example.com")))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "owner@example.com"),
            sourceLabel: "codex-cli",
            context: context)

        #expect(restored == nil)
        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    @Test
    func `cached dashboard provider account without scoped auth email fails closed`() throws {
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
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "shared@example.com",
            snapshot: self.makeDashboard(email: "shared@example.com")))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "shared@example.com"),
            sourceLabel: "codex-cli",
            context: context)

        #expect(restored == nil)
        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    @Test
    func `cached dashboard unresolved trusted continuity with competing owner returns nil`() {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let emptyHome = self.makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: emptyHome) }
        let context = self.makeContext(
            authHome: emptyHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-alpha"),
                    normalizedEmail: "shared@example.com"),
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-beta"),
                    normalizedEmail: "shared@example.com"),
            ])
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "shared@example.com",
            snapshot: self.makeDashboard(email: "shared@example.com")))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "shared@example.com"),
            sourceLabel: "codex-cli",
            context: context)

        #expect(restored == nil)
        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    @Test
    func `cached dashboard trusts codex cli usage continuity`() {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let emptyHome = self.makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: emptyHome) }
        let context = self.makeContext(
            authHome: emptyHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-owner"),
                    normalizedEmail: "owner@example.com"),
            ])
        let dashboard = self.makeDashboard(email: "owner@example.com")
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "stale-route@example.com",
            snapshot: dashboard))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "owner@example.com"),
            sourceLabel: "codex-cli",
            context: context)

        #expect(restored == dashboard)
    }

    @Test
    func `cached dashboard trusts oauth usage continuity`() {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let emptyHome = self.makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: emptyHome) }
        let context = self.makeContext(
            authHome: emptyHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-owner"),
                    normalizedEmail: "owner@example.com"),
            ])
        let dashboard = self.makeDashboard(email: "owner@example.com")
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "stale-route@example.com",
            snapshot: dashboard))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "owner@example.com"),
            sourceLabel: "oauth",
            context: context)

        #expect(restored == dashboard)
    }

    @Test
    func `cached dashboard does not trust open A I web usage continuity`() {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let emptyHome = self.makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: emptyHome) }
        let context = self.makeContext(
            authHome: emptyHome,
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-owner"),
                    normalizedEmail: "owner@example.com"),
            ])
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "owner@example.com",
            snapshot: self.makeDashboard(email: "owner@example.com")))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "owner@example.com"),
            sourceLabel: "openai-web",
            context: context)

        #expect(restored == nil)
        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    @Test
    func `cached dashboard ignores cached account email equality when authority rejects`() throws {
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
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "owner@example.com",
            snapshot: self.makeDashboard(email: "owner@example.com")))

        let restored = CodexBarCLI.loadOpenAIDashboardIfAvailable(
            usage: self.makeUsage(email: "owner@example.com"),
            sourceLabel: "codex-cli",
            context: context)

        #expect(restored == nil)
        #expect(OpenAIDashboardCacheStore.load() == nil)
    }

    private func makeContext(
        authHome: URL?,
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

    private func makeUsage(email: String?) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 7200),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 2000),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private func makeDashboard(email: String) -> OpenAIDashboardSnapshot {
        let creditEvents = [
            CreditEvent(
                date: Date(timeIntervalSince1970: 1000),
                service: "codex",
                creditsUsed: 3),
        ]
        return OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: 75,
            codeReviewLimit: RateWindow(
                usedPercent: 25,
                windowMinutes: 60,
                resetsAt: Date(timeIntervalSince1970: 3600),
                resetDescription: nil),
            creditEvents: creditEvents,
            dailyBreakdown: OpenAIDashboardSnapshot.makeDailyBreakdown(from: creditEvents, maxDays: 30),
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

    private func makeEmptyHome() -> URL {
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try? FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
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
