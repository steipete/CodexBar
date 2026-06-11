import Foundation
import Testing
@testable import CodexBar

struct PoeLoginRunnerTests {
    // MARK: - parseCallback: success path

    @Test
    func `callback parser accepts expected code and state`() {
        let request = """
        GET /callback?code=poe-code&state=expected-state HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.code == "poe-code")
        #expect(callback.returnedState == "expected-state")
        #expect(callback.error == nil)
        #expect(callback.errorDescription == nil)
    }

    @Test
    func `callback parser URL-decodes percent-encoded code and state`() {
        let request = """
        GET /callback?code=poe%2Bcode%3Dvalue&state=expected%20state HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected state")

        #expect(callback.code == "poe+code=value")
        #expect(callback.returnedState == "expected state")
        #expect(callback.error == nil)
    }

    @Test
    func `callback parser trims surrounding whitespace from values`() {
        let request = """
        GET /callback?code=%20poe-code%20&state=%20expected-state%20 HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.code == "poe-code")
        #expect(callback.returnedState == "expected-state")
    }

    @Test
    func `callback parser ignores untracked query parameters`() {
        let request = """
        GET /callback?code=poe-code&state=expected-state&session=abc&utm=zzz HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.code == "poe-code")
        #expect(callback.returnedState == "expected-state")
        #expect(callback.error == nil)
    }

    // MARK: - parseCallback: CSRF / duplicate / error paths

    @Test
    func `callback parser rejects duplicate tracked query parameters without crashing`() {
        let request = """
        GET /callback?code=poe-code&state=expected-state&state=duplicate-state HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.code == nil)
        #expect(callback.returnedState == nil)
        #expect(callback.error == "invalid_request")
        #expect(callback.errorDescription == "Duplicate callback parameter.")
    }

    @Test
    func `callback parser rejects duplicate code parameter`() {
        let request = """
        GET /callback?code=poe-code&code=duplicate-code HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.error == "invalid_request")
        #expect(callback.errorDescription == "Duplicate callback parameter.")
    }

    @Test
    func `callback parser rejects state mismatch with invalid_request`() {
        let request = """
        GET /callback?code=poe-code&state=attacker-state HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        // State is preserved (so caller can log it) but code is nulled because of CSRF mismatch
        #expect(callback.code == nil)
        #expect(callback.returnedState == "attacker-state")
        #expect(callback.error == "invalid_request")
        #expect(callback.errorDescription == "State mismatch.")
    }

    @Test
    func `callback parser surfaces error_description when present`() {
        let request = """
        GET /callback?error=access_denied&error_description=The%20user%20denied%20the%20request HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.code == nil)
        #expect(callback.error == "access_denied")
        #expect(callback.errorDescription == "The user denied the request")
    }

    @Test
    func `callback parser rejects duplicate error parameter`() {
        let request = """
        GET /callback?error=access_denied&error=server_error HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.error == "invalid_request")
        #expect(callback.errorDescription == "Duplicate callback parameter.")
    }

    @Test
    func `callback parser accepts a callback with no query parameters`() {
        let request = """
        GET /callback HTTP/1.1\r
        Host: 127.0.0.1\r
        \r
        """

        let callback = PoeLoginRunner._parseCallbackForTesting(
            request,
            expectedState: "expected-state")

        #expect(callback.code == nil)
        #expect(callback.returnedState == nil)
        #expect(callback.error == nil)
    }

    // MARK: - makeCodeChallenge (PKCE)

    @Test
    func `code challenge uses SHA256 of the verifier`() {
        // Verifier from RFC 7636 §4.6 example
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PoeLoginRunner._makeCodeChallengeForTesting(verifier: verifier)

        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test
    func `code challenge is base64URL-encoded without padding`() {
        let challenge = PoeLoginRunner._makeCodeChallengeForTesting(verifier: "any-verifier")

        // base64URL alphabet: A-Z a-z 0-9 - _
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(challenge.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test
    func `code challenge is deterministic for the same verifier`() {
        let verifier = "the-same-verifier-string"
        let a = PoeLoginRunner._makeCodeChallengeForTesting(verifier: verifier)
        let b = PoeLoginRunner._makeCodeChallengeForTesting(verifier: verifier)

        #expect(a == b)
    }

    @Test
    func `code challenge differs for different verifiers`() {
        let a = PoeLoginRunner._makeCodeChallengeForTesting(verifier: "verifier-a")
        let b = PoeLoginRunner._makeCodeChallengeForTesting(verifier: "verifier-b")

        #expect(a != b)
    }

    // MARK: - makeAuthorizationURL

    @Test
    func `authorization URL points at poe.com oauth authorize endpoint`() throws {
        let redirect = try #require(URL(string: "http://127.0.0.1:52183/callback"))
        let url = try PoeLoginRunner._makeAuthorizationURLForTesting(
            clientID: "test-client",
            redirectURL: redirect,
            state: "abc-state",
            codeChallenge: "challenge-value")

        #expect(url.scheme == "https")
        #expect(url.host == "poe.com")
        #expect(url.path == "/oauth/authorize")
    }

    @Test
    func `authorization URL includes all required PKCE and OAuth parameters`() throws {
        let redirect = try #require(URL(string: "http://127.0.0.1:52183/callback"))
        let url = try PoeLoginRunner._makeAuthorizationURLForTesting(
            clientID: "test-client",
            redirectURL: redirect,
            state: "abc-state",
            codeChallenge: "challenge-value")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(query["client_id"] == "test-client")
        #expect(query["redirect_uri"] == "http://127.0.0.1:52183/callback")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "apikey:create")
        #expect(query["code_challenge"] == "challenge-value")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "abc-state")
    }

    @Test
    func `authorization URL carries no extra parameters beyond the PKCE and OAuth set`() throws {
        let redirect = try #require(URL(string: "http://127.0.0.1:52183/callback"))
        let url = try PoeLoginRunner._makeAuthorizationURLForTesting(
            clientID: "test-client",
            redirectURL: redirect,
            state: "abc-state",
            codeChallenge: "challenge-value")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let allowedKeys: Set<String> = [
            "client_id",
            "redirect_uri",
            "response_type",
            "scope",
            "code_challenge",
            "code_challenge_method",
            "state",
        ]
        let actualKeys = Set((components.queryItems ?? []).map(\.name))
        #expect(actualKeys.isSubset(of: allowedKeys))
        #expect(actualKeys.count == allowedKeys.count)
    }

    // MARK: - oauthClientID

    @Test
    func `oauth client id is nil when env var is absent`() {
        let value = PoeLoginRunner._oauthClientIDForTesting(environment: [:])
        #expect(value == nil)
    }

    @Test
    func `oauth client id is nil when env var is empty`() {
        let value = PoeLoginRunner._oauthClientIDForTesting(environment: ["POE_OAUTH_CLIENT_ID": ""])
        #expect(value == nil)
    }

    @Test
    func `oauth client id is nil when env var is whitespace only`() {
        let value = PoeLoginRunner._oauthClientIDForTesting(environment: ["POE_OAUTH_CLIENT_ID": "   \n\t  "])
        #expect(value == nil)
    }

    @Test
    func `oauth client id trims surrounding whitespace`() {
        let value = PoeLoginRunner._oauthClientIDForTesting(environment: ["POE_OAUTH_CLIENT_ID": "  my-client  "])
        #expect(value == "my-client")
    }

    @Test
    func `oauth client id returns the raw value when no surrounding whitespace`() {
        let value = PoeLoginRunner._oauthClientIDForTesting(environment: ["POE_OAUTH_CLIENT_ID": "my-client"])
        #expect(value == "my-client")
    }

    @Test
    func `oauth client id ignores other env vars`() {
        let value = PoeLoginRunner._oauthClientIDForTesting(environment: [
            "PATH": "/usr/bin",
            "POE_OAUTH_CLIENT_ID": "real-client",
        ])
        #expect(value == "real-client")
    }
}
