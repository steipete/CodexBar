import Foundation
import Testing
@testable import CodexBarCore

struct AmpUsageFetcherTests {
    private func makeContext(
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `uses amp internal usage endpoint`() {
        #expect(
            AmpUsageFetcher.usageURL.absoluteString ==
                "https://ampcode.com/api/internal?userDisplayBalanceInfo")
    }

    @Test
    func `provider dashboard points to current usage page`() {
        #expect(AmpProviderDescriptor.descriptor.metadata.dashboardURL == "https://ampcode.com/settings/usage")
    }

    @Test
    func `web fallback requires browser import or a manual session cookie`() {
        let disabled = ProviderSettingsSnapshot.AmpProviderSettings(cookieSource: .off, manualCookieHeader: nil)
        let invalidManual = ProviderSettingsSnapshot.AmpProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "other=value")
        let validManual = ProviderSettingsSnapshot.AmpProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "session=test")

        #expect(AmpStatusFetchStrategy.canUseWebFallback(
            settings: nil,
            canImportBrowserCookies: false) == false)
        #expect(AmpStatusFetchStrategy.canUseWebFallback(
            settings: nil,
            canImportBrowserCookies: true))
        #expect(AmpStatusFetchStrategy.canUseWebFallback(
            settings: disabled,
            canImportBrowserCookies: true) == false)
        #expect(AmpStatusFetchStrategy.canUseWebFallback(
            settings: invalidManual,
            canImportBrowserCookies: false) == false)
        #expect(AmpStatusFetchStrategy.canUseWebFallback(
            settings: validManual,
            canImportBrowserCookies: false))
    }

    @Test
    func `cli cancellation does not fall back to web`() {
        let strategy = AmpCLIFetchStrategy()
        let context = self.makeContext(sourceMode: .auto)

        #expect(!strategy.shouldFallback(on: CancellationError(), context: context))
        #expect(!strategy.shouldFallback(on: URLError(.cancelled), context: context))
        #expect(strategy.shouldFallback(on: AmpUsageError.parseFailed("missing"), context: context))
        #expect(!strategy.shouldFallback(
            on: AmpUsageError.parseFailed("missing"),
            context: self.makeContext(sourceMode: .cli)))
    }

    @Test
    func `api request uses bearer token without cookies`() throws {
        let request = try AmpUsageFetcher.makeUsageAPIRequest(apiToken: "sgamp_test")

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sgamp_test")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test
    func `api strategy falls back only from auto mode and preserves cancellation`() {
        let strategy = AmpAPIFetchStrategy()
        let auto = self.makeContext(sourceMode: .auto)

        #expect(strategy.shouldFallback(on: AmpUsageError.missingAPIToken, context: auto))
        #expect(strategy.shouldFallback(on: AmpUsageError.invalidAPIToken, context: auto))
        #expect(strategy.shouldFallback(on: URLError(.timedOut), context: auto))
        #expect(!strategy.shouldFallback(on: CancellationError(), context: auto))
        #expect(!strategy.shouldFallback(on: URLError(.cancelled), context: auto))
        #expect(!strategy.shouldFallback(
            on: AmpUsageError.invalidAPIToken,
            context: self.makeContext(sourceMode: .api)))
    }

    @Test
    func `amp config token resolves through environment`() {
        let env = [AmpSettingsReader.apiTokenKey: " 'sgamp_test' "]

        #expect(ProviderTokenResolver.ampToken(environment: env) == "sgamp_test")
    }

    @Test
    func `attaches cookie for amp hosts`() {
        #expect(AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://ampcode.com/settings")))
        #expect(AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://www.ampcode.com")))
        #expect(AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://app.ampcode.com/path")))
    }

    @Test
    func `rejects non amp hosts`() {
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://example.com")))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://ampcode.com.evil.com")))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: nil))
    }

    @Test
    func `rejects non https amp urls`() {
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "http://ampcode.com/settings")))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "http://www.ampcode.com")))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "http://app.ampcode.com/path")))
    }

    @Test
    func `detects login redirects`() throws {
        let signIn = try #require(URL(string: "https://ampcode.com/auth/sign-in?returnTo=%2Fsettings"))
        #expect(AmpUsageFetcher.isLoginRedirect(signIn))

        let downgradedSignIn = try #require(URL(string: "http://ampcode.com/auth/sign-in?returnTo=%2Fsettings"))
        #expect(AmpUsageFetcher.isLoginRedirect(downgradedSignIn))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: downgradedSignIn))

        let sso = try #require(URL(string: "https://ampcode.com/auth/sso?returnTo=%2Fsettings"))
        #expect(AmpUsageFetcher.isLoginRedirect(sso))

        let login = try #require(URL(string: "https://ampcode.com/login"))
        #expect(AmpUsageFetcher.isLoginRedirect(login))

        let signin = try #require(URL(string: "https://www.ampcode.com/signin"))
        #expect(AmpUsageFetcher.isLoginRedirect(signin))

        let hostedAuth = try #require(URL(
            string: "https://auth.ampcode.com/?client_id=test&redirect_uri=https%3A%2F%2Fampcode.com%2Fauth%2Fcallback"))
        #expect(AmpUsageFetcher.isLoginRedirect(hostedAuth))
    }

    @Test
    func `ignores non login UR ls`() throws {
        let settings = try #require(URL(string: "https://ampcode.com/settings"))
        #expect(!AmpUsageFetcher.isLoginRedirect(settings))

        let signOut = try #require(URL(string: "https://ampcode.com/auth/sign-out"))
        #expect(!AmpUsageFetcher.isLoginRedirect(signOut))

        let evil = try #require(URL(string: "https://ampcode.com.evil.com/auth/sign-in"))
        #expect(!AmpUsageFetcher.isLoginRedirect(evil))
    }
}
