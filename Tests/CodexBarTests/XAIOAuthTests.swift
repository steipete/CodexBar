import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit
#endif

struct XAIOAuthTests {
    @Test
    func `routes management keys bearers and cookies`() {
        #expect(
            XAICredentialRouting.resolve(
                tokenAccountToken: "xai-management-key",
                manualCookieHeader: nil) == .managementAPI)
        #expect(
            XAICredentialRouting.resolve(
                tokenAccountToken: "Bearer supergrok-oauth-test-token",
                manualCookieHeader: nil) == .oauth(accessToken: "supergrok-oauth-test-token"))
        #expect(
            XAICredentialRouting.resolve(
                tokenAccountToken: "sso=abc; sso-rw=def",
                manualCookieHeader: nil) == .webCookie(header: "sso=abc; sso-rw=def"))
        #expect(
            XAICredentialRouting.resolve(
                tokenAccountToken: nil,
                manualCookieHeader: "Cookie: sso=abc") == .webCookie(header: "sso=abc"))
        #expect(XAICredentialRouting.isManagementAPIKey("xai-abc") == true)
        #expect(XAICredentialRouting.normalizedOAuthToken("xai-abc") == nil)
    }

    @Test
    func `oauth fetch sends CLI proxy headers and maps SuperGrok credits`() async throws {
        let reset = try Self.date("2026-08-13T00:00:00Z")
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
            #expect(request.httpMethod == "GET")
            #expect(
                request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-supergrok-token")
            #expect(request.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexBar")
            return Self.response(
                url: url,
                body: """
                {
                  "config": {
                    "creditUsagePercent": 12.5,
                    "currentPeriod": { "end": "2026-08-13T00:00:00Z" }
                  }
                }
                """)
        }

        let credits = try await XAIOAuthCreditsFetcher.fetch(
            accessToken: "fixture-supergrok-token",
            session: transport)
        #expect(credits.usedPercent == 12.5)
        #expect(credits.resetsAt == reset)

        let snapshot = XAIOAuthUsageMapper.usageSnapshot(credits: credits, updatedAt: reset)
        #expect(snapshot.primary?.usedPercent == 12.5)
        #expect(snapshot.loginMethod(for: .xai) == "SuperGrok")
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.providerCost == nil)
        #expect(
            XAIProviderDescriptor.primaryLabel(
                snapshot: snapshot, now: reset.addingTimeInterval(-4 * 86400))
                == "Weekly")
    }

    @Test
    func `oauth parse goldens match Grok CLI proxy contract`() throws {
        let percent = try XAIOAuthCreditsFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "onDemandCap": { "val": 1000.0 },
                    "onDemandUsed": { "val": 250.5 }
                  }
                }
                """.utf8))
        #expect(percent.usedPercent == 25.05)

        let zero = try XAIOAuthCreditsFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "currentPeriod": { "end": "2026-08-13T00:00:00Z" }
                  }
                }
                """.utf8))
        #expect(zero.usedPercent == 0)
        #expect(try zero.resetsAt == (Self.date("2026-08-13T00:00:00Z")))
        #expect(zero.subscriptionTier == nil)
    }

    @Test
    func `reads SuperGrok Heavy from the credits subscription tier`() throws {
        let snapshot = try XAIOAuthCreditsFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "currentPeriod": { "end": "2026-08-23T18:42:45Z" },
                    "onDemandCap": { "val": 0 },
                    "onDemandUsed": { "val": 0 }
                  },
                  "subscriptionTier": "SuperGrok Heavy"
                }
                """.utf8))
        #expect(snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(snapshot.usedPercent == nil)
        #expect(try snapshot.resetsAt == Self.date("2026-08-23T18:42:45Z"))

        let usage = XAIOAuthUsageMapper.usageSnapshot(credits: snapshot)
        #expect(usage.loginMethod(for: .xai) == "SuperGrok Heavy")
        #expect(usage.primary == nil)
        #expect(XAIOAuthUsageMapper.isSuperGrokFamily("SuperGrok Heavy"))
    }

    @Test
    func `prefers config subscription tier over the envelope`() throws {
        let snapshot = try XAIOAuthCreditsFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": {
                    "creditUsagePercent": 8,
                    "billingPeriodEnd": "2026-08-13T00:00:00Z",
                    "subscriptionTier": "SuperGrok Heavy"
                  },
                  "subscriptionTier": "SuperGrok"
                }
                """.utf8))
        #expect(snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(snapshot.usedPercent == 8)
        #expect(
            XAIOAuthUsageMapper.usageSnapshot(credits: snapshot).loginMethod(for: .xai)
                == "SuperGrok Heavy")
    }

    @Test
    func `keeps SuperGrok Heavy identity when only the tier is present`() throws {
        let snapshot = try XAIOAuthCreditsFetcher.parseSnapshot(
            Data(
                """
                {
                  "config": { "onDemandCap": { "val": 0 } },
                  "subscriptionTier": "supergrok_heavy"
                }
                """.utf8))
        #expect(snapshot.subscriptionTier == "SuperGrok Heavy")
        #expect(snapshot.usedPercent == nil)
        #expect(snapshot.resetsAt == nil)
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .authenticationExpired),
        (429, .rateLimited),
        (503, .apiFailure),
    ])
    func `oauth errors stay classified`(
        status: Int,
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: "nope", statusCode: status)
        }
        do {
            _ = try await XAIOAuthCreditsFetcher.fetch(accessToken: "token", session: transport)
            Issue.record("Expected classified SuperGrok failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        }
    }

    @Test
    func `oauth strategy is unavailable without a SuperGrok token`() async {
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .oauth,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: XAIOAuthTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let available = await XAIOAuthFetchStrategy().isAvailable(context)
        #expect(available == false)
    }

    @Test
    func `auto keeps management API ahead of SuperGrok oauth`() async {
        let strategies = await XAIProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(
                ProviderFetchContext(
                    runtime: .app,
                    sourceMode: .auto,
                    includeCredits: false,
                    webTimeout: 1,
                    webDebugDumpHTML: false,
                    verbose: false,
                    env: [
                        XAISettingsReader.apiKeyEnvironmentKey: "xai-management",
                        XAISettingsReader.teamIDEnvironmentKey: "team-1234",
                        XAISettingsReader.oauthTokenEnvironmentKey: "oauth-token",
                    ],
                    settings: nil,
                    fetcher: UsageFetcher(environment: [:]),
                    claudeFetcher: XAIOAuthTestClaudeFetcher(),
                    browserDetection: BrowserDetection(cacheTTL: 0)))
        #expect(strategies.map(\.id) == ["xai.js", "xai.oauth", "xai.web"])
        #expect(strategies.map(\.kind) == [.apiToken, .oauth, .web])
    }

    @Test
    func `browser cookies keep SuperGrok oauth ahead of grok.com billing`() async {
        let strategies = await XAIProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(
                ProviderFetchContext(
                    runtime: .app,
                    sourceMode: .web,
                    includeCredits: false,
                    webTimeout: 1,
                    webDebugDumpHTML: false,
                    verbose: false,
                    env: [:],
                    settings: nil,
                    fetcher: UsageFetcher(environment: [:]),
                    claudeFetcher: XAIOAuthTestClaudeFetcher(),
                    browserDetection: BrowserDetection(cacheTTL: 0)))
        #expect(strategies.map(\.id) == ["xai.oauth", "xai.web"])
        #expect(strategies.map(\.kind) == [.oauth, .web])
    }

    @Test
    func `chrome is the only default xAI cookie browser`() {
        #if os(macOS)
        #expect(XAIProviderDescriptor.descriptor.metadata.browserCookieOrder == [.chrome])
        #else
        #expect(XAIProviderDescriptor.descriptor.metadata.browserCookieOrder == nil)
        #endif
    }

    @Test
    func `SuperGrok family covers Heavy and keeps the grok usage dashboard`() {
        #expect(XAIOAuthUsageMapper.isSuperGrokFamily("SuperGrok"))
        #expect(XAIOAuthUsageMapper.isSuperGrokFamily("SuperGrok Heavy"))
        #expect(XAIOAuthUsageMapper.isSuperGrokFamily("supergrok_heavy"))
        #expect(!XAIOAuthUsageMapper.isSuperGrokFamily("Management API"))
        #expect(!XAIOAuthUsageMapper.isSuperGrokFamily(nil))
        #expect(
            XAIProviderDescriptor.descriptor.metadata.subscriptionDashboardURL
                == XAIOAuthUsageMapper.superGrokUsageDashboardURL)
    }

    @Test
    func `SuperGrok token file is the Grok Build auth file`() {
        let url = XAISettingsReader.grokAuthFileURL(environment: [:])
        #expect(url.lastPathComponent == "auth.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == ".grok")
        #expect(url.path == GrokCredentialsStore.authFileURL(env: [:]).path)
    }

    @Test
    func `identity-only oauth does not block the cookie path`() {
        let empty = XAIOAuthUsageMapper.usageSnapshot(
            credits: XAIOAuthCreditsSnapshot(
                usedPercent: nil,
                resetsAt: nil,
                subscriptionTier: "SuperGrok"))
        let used = XAIOAuthUsageMapper.usageSnapshot(
            credits: XAIOAuthCreditsSnapshot(usedPercent: 12.5, resetsAt: nil))
        #expect(XAIWebFetchStrategy.shouldContinueToCookies(afterOAuthUsage: empty))
        #expect(!XAIWebFetchStrategy.shouldContinueToCookies(afterOAuthUsage: used))
    }

    @Test
    func `explicit web source stays available without cached cookies`() async {
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(
                xai: XAIProviderSettings(
                    usageDataSource: .web,
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                    allowGrokCLICredentials: false)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: XAIOAuthTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let available = await XAIWebFetchStrategy().isAvailable(context)
        #expect(available == true)
    }

    @Test
    func `explicit web picker is not remapped by a stored oauth token`() {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "SuperGrok",
            token: "Bearer supergrok-oauth-test-token",
            addedAt: 0,
            lastUsed: nil)
        let mode = XAIProviderDescriptor.descriptor.credentials?.selectedAccountSourceMode(
            base: .web,
            account: account,
            config: nil)
        #expect(mode == .web)

        let settings = XAIProviderSettings.resolved(
            pickerSource: .web,
            tokenAccountToken: account.token,
            configuredCookieSource: .auto,
            configuredCookieHeader: nil,
            allowGrokCLICredentials: false)
        #expect(settings.usageDataSource == .web)
        #expect(settings.cookieSource == .auto)
    }

    @Test
    func `auto picker remaps oauth tokens and disables cookies`() {
        let settings = XAIProviderSettings.resolved(
            pickerSource: .auto,
            tokenAccountToken: "Bearer supergrok-oauth-test-token",
            configuredCookieSource: .auto,
            configuredCookieHeader: nil,
            allowGrokCLICredentials: false)
        #expect(settings.usageDataSource == .oauth)
        #expect(settings.cookieSource == .off)
    }

    private static func date(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: raw))
    }

    private static func response(url: URL, body: String, statusCode: Int = 200) -> (Data, URLResponse) {
        let response =
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]) ?? HTTPURLResponse()
        return (Data(body.utf8), response)
    }
}

private struct XAIOAuthTestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }

    func detectVersion() -> String? {
        nil
    }
}
