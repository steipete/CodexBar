import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct MiniMaxLogRedactorTests {
    private static var miniMaxCpPlaceholder: String {
        ["sk", "cp", "placeholder"].joined(separator: "-")
    }

    private static var miniMaxApiPlaceholder: String {
        ["sk", "api", "placeholder"].joined(separator: "-")
    }

    @Test
    func `sk-cp token is redacted`() {
        let input = Self.miniMaxCpPlaceholder
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("sk-cp-") == false)
        #expect(redacted.contains("<redacted-minimax-token>"))
        #expect(redacted.contains("placeholder") == false)
    }

    @Test
    func `sk-api token is redacted`() {
        let input = Self.miniMaxApiPlaceholder
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("sk-api-") == false)
        #expect(redacted.contains("<redacted-minimax-token>"))
        #expect(redacted.contains("placeholder") == false)
    }

    @Test
    func `cookie header is redacted`() {
        let input = "Cookie: session=cookie-session-placeholder; token=\(Self.miniMaxCpPlaceholder)"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("session=cookie-session-placeholder") == false)
        #expect(redacted.contains(Self.miniMaxCpPlaceholder) == false)
        #expect(redacted.contains("Cookie: <redacted>"))
    }

    @Test
    func `authorization header value is redacted`() {
        // Short obvious placeholder, not JWT-like
        let input = "Authorization: Bearer fake-bearer-token"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("fake-bearer-token") == false)
        #expect(redacted.contains("Authorization:"))
    }

    @Test
    func `bearer token is not present in raw form`() {
        let input = "Authorization: bearer \(Self.miniMaxApiPlaceholder)"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains(Self.miniMaxApiPlaceholder) == false)
    }

    @Test
    func `email is redacted`() {
        let input = "Contact: user@example.com"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("user@example.com") == false)
        #expect(redacted.contains("<redacted-email>"))
    }

    @Test
    func `minimax token in cookie is not present in raw form`() {
        let input = "Cookie: session=session-placeholder; token=\(Self.miniMaxCpPlaceholder)"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("session=session-placeholder") == false)
        #expect(redacted.contains(Self.miniMaxCpPlaceholder) == false)
    }

    @Test
    func `redacted text no longer matches original token pattern`() {
        let originalToken = Self.miniMaxCpPlaceholder
        let input = "Token: \(originalToken)"
        let redacted = LogRedactor.redact(input)

        #expect(redacted.contains(originalToken) == false)
        #expect(redacted.contains("<redacted-minimax-token>"))
    }

    @Test
    func `minimax token with punctuation suffix is fully redacted`() {
        let punctuatedToken = "\(Self.miniMaxApiPlaceholder).suffix-more"
        let input = "Error: token=\(punctuatedToken)"
        let redacted = LogRedactor.redact(input)

        #expect(redacted.contains("sk-api-") == false)
        #expect(redacted.contains("suffix-more") == false)
        #expect(redacted.contains("<redacted-minimax-token>"))
    }

    @Test
    func `authorization header minimax token leaves no suffix fragment`() {
        let punctuatedToken = "\(Self.miniMaxCpPlaceholder)-part.two"
        let input = "Authorization: Bearer \(punctuatedToken)"
        let redacted = LogRedactor.redact(input)

        #expect(redacted.contains("sk-cp-") == false)
        #expect(redacted.contains("part.two") == false)
        #expect(redacted.contains("Authorization: <redacted>"))
    }
}
