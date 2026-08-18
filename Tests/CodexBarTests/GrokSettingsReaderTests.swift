import Foundation
import Testing
@testable import CodexBarCore

struct GrokSettingsReaderTests {
    @Test
    func `normalizes a pasted SuperGrok bearer and rejects cookies`() {
        #expect(GrokSettingsReader.normalizedOAuthToken("  Bearer abc.def.ghi  ") == "abc.def.ghi")
        #expect(GrokSettingsReader.normalizedOAuthToken("Cookie: sso=abc") == nil)
        #expect(GrokSettingsReader.normalizedOAuthToken("sso=abc; sso-rw=def") == nil)
        #expect(GrokSettingsReader.normalizedOAuthToken("xai-mgmt-key") == nil)
        #expect(GrokSettingsReader.normalizedOAuthToken("   ") == nil)
    }

    @Test
    func `reads pasted SuperGrok credentials from GROK_OAUTH_TOKEN`() {
        let env = [GrokSettingsReader.oauthTokenEnvironmentKey: "Bearer pasted-token"]
        let creds = GrokSettingsReader.pastedCredentials(environment: env)

        #expect(creds?.accessToken == "pasted-token")
        #expect(creds?.loginMethod == "SuperGrok")
        #expect(GrokSettingsReader.oauthAccessToken(environment: [:]) == nil)
    }

    @Test
    func `prefers a pasted SuperGrok token when auth json is expired`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokExpiredAuth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(
            """
            {
              "https://auth.x.ai::client": {
                "key": "stale-file-token",
                "auth_mode": "oidc",
                "expires_at": "2020-01-01T00:00:00Z"
              }
            }
            """.utf8).write(to: home.appendingPathComponent("auth.json"))

        var env = [GrokSettingsReader.oauthTokenEnvironmentKey: "pasted-token"]
        env["GROK_HOME"] = home.path
        #expect(GrokSettingsReader.resolvedCredentials(environment: env)?.accessToken == "pasted-token")
    }

    @Test
    func `descriptor exposes SuperGrok token accounts`() {
        let support = GrokProviderDescriptor.descriptor.credentials?.tokenAccountSupport
        #expect(support?.title == "SuperGrok tokens")
        if case let .environment(key) = support?.injection {
            #expect(key == GrokSettingsReader.oauthTokenEnvironmentKey)
        } else {
            Issue.record("expected environment token injection")
        }
        #expect(
            support?.envOverride(token: "pasted-token") == [
                GrokSettingsReader.oauthTokenEnvironmentKey: "pasted-token",
            ])
        #expect(
            support?.envOverride(token: "Bearer abc.def.ghi") == [
                GrokSettingsReader.oauthTokenEnvironmentKey: "abc.def.ghi",
            ])
        #expect(support?.envOverride(token: "Cookie: sso=abc") == nil)
    }

    @Test
    func `classifies bearer, cookie, and management-key secrets`() {
        #expect(
            GrokCredentialRouting.resolve(
                tokenAccountToken: "Bearer abc.def", manualCookieHeader: nil)
                == .oauth(accessToken: "abc.def"))
        #expect(
            GrokCredentialRouting.resolve(
                tokenAccountToken: "Cookie: sso=abc", manualCookieHeader: nil)
                == .webCookie(header: "sso=abc"))
        #expect(
            GrokCredentialRouting.resolve(
                tokenAccountToken: "xai-mgmt-key", manualCookieHeader: nil) == .none)
        #expect(
            GrokCredentialRouting.resolve(
                tokenAccountToken: nil, manualCookieHeader: "sso=abc; sso-rw=def")
                == .webCookie(header: "sso=abc; sso-rw=def"))
    }

    @Test
    func `selected SuperGrok accounts remap to oauth or web, never an empty oauth pipeline`() {
        let adapter = GrokProviderDescriptor.descriptor.credentials
        let oauthAccount = ProviderTokenAccount(
            id: UUID(),
            label: "oauth",
            token: "pasted-token",
            addedAt: 0,
            lastUsed: nil)
        let cookieAccount = ProviderTokenAccount(
            id: UUID(),
            label: "cookie",
            token: "Cookie: sso=abc",
            addedAt: 0,
            lastUsed: nil)
        #expect(
            adapter?.selectedAccountSourceMode(base: .auto, account: oauthAccount, config: nil)
                == .oauth)
        #expect(
            adapter?.selectedAccountSourceMode(base: .auto, account: cookieAccount, config: nil)
                == .web)
        #expect(adapter?.selectedAccountSourceMode(base: .auto, account: nil, config: nil) == .auto)
        #expect(
            adapter?.selectedAccountSourceMode(base: .cli, account: oauthAccount, config: nil) == .cli)
        #expect(
            adapter?.selectedAccountSourceMode(base: .web, account: oauthAccount, config: nil) == .web)
        #expect(
            GrokProviderDescriptor.descriptor.fetchPlan.sourceModes == [.auto, .cli, .oauth, .web])
    }

    @Test
    func `selected pasted SuperGrok token wins over a valid auth json file`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokSelectedBearer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(
            """
            {
              "https://auth.x.ai::client": {
                "key": "file-token",
                "auth_mode": "oidc"
              }
            }
            """.utf8).write(to: home.appendingPathComponent("auth.json"))

        var env = [GrokSettingsReader.oauthTokenEnvironmentKey: "pasted-token"]
        env["GROK_HOME"] = home.path
        #expect(GrokSettingsReader.resolvedCredentials(environment: env)?.accessToken == "pasted-token")
        env.removeValue(forKey: GrokSettingsReader.oauthTokenEnvironmentKey)
        #expect(GrokSettingsReader.resolvedCredentials(environment: env)?.accessToken == "file-token")
    }

    @Test
    func `selected cookie account overrides the configured Grok cookie header`() {
        let selected = GrokCredentialRouting.cookieSettings(
            configuredSource: .auto,
            configuredHeader: "sso=configured",
            selectedAccountToken: "Cookie: sso=selected")
        #expect(selected.cookieSource == .manual)
        #expect(selected.manualCookieHeader == "sso=selected")

        let bearerKeepsConfigured = GrokCredentialRouting.cookieSettings(
            configuredSource: .auto,
            configuredHeader: "sso=configured",
            selectedAccountToken: "pasted-token")
        #expect(bearerKeepsConfigured.cookieSource == .auto)
        #expect(bearerKeepsConfigured.manualCookieHeader == "sso=configured")

        let none = GrokCredentialRouting.cookieSettings(
            configuredSource: .auto,
            configuredHeader: "sso=configured",
            selectedAccountToken: nil)
        #expect(none.cookieSource == .auto)
        #expect(none.manualCookieHeader == "sso=configured")
    }

    @Test
    func `auto tries SuperGrok OAuth before cookies and after the CLI`() async {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        func makeContext(sourceMode: ProviderSourceMode) -> ProviderFetchContext {
            ProviderFetchContext(
                runtime: .app,
                sourceMode: sourceMode,
                includeCredits: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: [:],
                settings: nil,
                fetcher: UsageFetcher(),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
                browserDetection: browserDetection)
        }
        let auto = makeContext(sourceMode: .auto)
        let web = makeContext(sourceMode: .web)
        let strategies = await GrokProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(auto)
        #expect(strategies.map(\.id) == ["grok.cli", "grok.oauth", "grok.web", "grok.oauth-grpc"])
        #expect(
            GrokWebFetchStrategy().shouldFallback(
                on: GrokWebBillingError.missingCredentials,
                context: auto))
        #expect(
            !GrokWebFetchStrategy().shouldFallback(
                on: GrokWebBillingError.missingCredentials,
                context: web))
    }
}
