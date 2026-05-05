import Foundation
import Testing
@testable import CodexBarCore

struct AmpUsageFetcherTests {
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
    func `detects login redirects`() throws {
        let signIn = try #require(URL(string: "https://ampcode.com/auth/sign-in?returnTo=%2Fsettings"))
        #expect(AmpUsageFetcher.isLoginRedirect(signIn))

        let sso = try #require(URL(string: "https://ampcode.com/auth/sso?returnTo=%2Fsettings"))
        #expect(AmpUsageFetcher.isLoginRedirect(sso))

        let login = try #require(URL(string: "https://ampcode.com/login"))
        #expect(AmpUsageFetcher.isLoginRedirect(login))

        let signin = try #require(URL(string: "https://www.ampcode.com/signin"))
        #expect(AmpUsageFetcher.isLoginRedirect(signin))
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
