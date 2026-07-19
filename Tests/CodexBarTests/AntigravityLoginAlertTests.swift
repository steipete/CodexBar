import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AntigravityLoginAlertTests {
    @Test
    func `authorization URL asks Google to select an account`() throws {
        let redirectURL = try #require(URL(string: "http://127.0.0.1:54321/callback"))
        let url = try AntigravityLoginRunner.makeAuthorizationURL(
            redirectURL: redirectURL,
            state: "state",
            oauthClient: AntigravityOAuthClient(
                clientID: "client.apps.googleusercontent.com",
                clientSecret: "secret"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let prompt = components.queryItems?.first(where: { $0.name == "prompt" })?.value

        #expect(prompt?.split(separator: " ").contains("select_account") == true)
        #expect(prompt?.split(separator: " ").contains("consent") == true)
    }

    @Test
    func `returns alert for timeout`() {
        let result = AntigravityLoginRunner.Result(outcome: .timedOut)
        let info = StatusItemController.antigravityLoginAlertInfo(for: result)
        #expect(info?.title == "Antigravity login timed out")
    }

    @Test
    func `returns alert for launch failure`() {
        let result = AntigravityLoginRunner.Result(outcome: .launchFailed("https://example.com/login"))
        let info = StatusItemController.antigravityLoginAlertInfo(for: result)
        #expect(info?.title == "Could not open browser for Antigravity")
        #expect(info?.message.contains("https://example.com/login") == true)
    }

    @Test
    func `returns alert for auth failure`() {
        let result = AntigravityLoginRunner.Result(outcome: .failed("permission denied"))
        let info = StatusItemController.antigravityLoginAlertInfo(for: result)
        #expect(info?.title == "Antigravity login failed")
        #expect(info?.message == "permission denied")
    }

    @Test
    func `returns nil on success`() {
        let result = AntigravityLoginRunner.Result(outcome: .success("user@example.com"))
        let info = StatusItemController.antigravityLoginAlertInfo(for: result)
        #expect(info == nil)
    }
}
