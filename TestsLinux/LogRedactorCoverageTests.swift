import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct LogRedactorCoverageTests {
    @Test
    func `openai-style sk token is redacted`() {
        let input = "Error: sk-proj-abcdef0123456789abcdef01 was rejected"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("abcdef0123456789abcdef01") == false)
        #expect(redacted.contains("<redacted-token>"))
    }

    @Test
    func `xai token is redacted`() {
        let input = "key=xai-abcdef0123456789abcdef01234567"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("abcdef0123456789abcdef01234567") == false)
        #expect(redacted.contains("<redacted-token>"))
    }

    @Test
    func `groq gsk token is redacted`() {
        let input = "key=gsk_abcdef0123456789abcdef01234567"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("abcdef0123456789abcdef01234567") == false)
        #expect(redacted.contains("<redacted-token>"))
    }

    @Test
    func `jwt is redacted`() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let input = "token=\(jwt)"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains(jwt) == false)
        #expect(redacted.contains("<redacted-jwt>"))
    }

    @Test
    func `x-api-key header value is redacted`() {
        let input = "X-Api-Key: abcdef0123456789"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("abcdef0123456789") == false)
        #expect(redacted.contains("X-Api-Key: <redacted>"))
    }

    @Test
    func `api_key label value is redacted`() {
        let input = "api_key=abcdef0123456789"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("abcdef0123456789") == false)
        #expect(redacted.contains("api_key=<redacted>"))
    }

    @Test
    func `mixed case provider tokens are redacted`() {
        for token in [
            "xai-AbCdEfGhIjKlMnOpQrStUvWxYz01",
            "gsk_AbCdEfGhIjKlMnOpQrStUvWxYz01",
            "pplx-AbCdEfGhIjKlMnOpQrStUvWxYz01",
            "hf_AbCdEfGhIjKlMnOpQrStUvWxYz01",
            "AIzaAbCdEfGhIjKlMnOpQrStUvWxYz01",
        ] {
            let input = "key=\(token)"
            let redacted = LogRedactor.redact(input)
            #expect(redacted.contains(token) == false, "expected \(token) to be redacted")
            #expect(redacted.contains("<redacted-token>"))
        }
    }

    @Test
    func `spaced api key label value is redacted`() {
        let input = "api key: abcdef0123456789"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("abcdef0123456789") == false)
        #expect(redacted.contains("api key: <redacted>"))
    }

    @Test
    func `query secret redaction keeps compact json valid`() throws {
        let input = #"{"url":"https://api.example?token=secretvalue123","provider":"kimi"}"#
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("secretvalue123") == false)
        let data = try #require(redacted.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["provider"] as? String == "kimi")
    }

    @Test
    func `url query token parameter is redacted`() {
        let input = "https://api.example.com/v1/usage?token=secretvalue123&format=json"
        let redacted = LogRedactor.redact(input)
        #expect(redacted.contains("secretvalue123") == false)
        #expect(redacted.contains("?token=<redacted>&format=json"))
    }

    @Test
    func `plain text without secrets is unchanged`() {
        let input = "refresh completed: 3 providers updated, next poll in 300s"
        #expect(LogRedactor.redact(input) == input)
    }

    @Test
    func `prose mentioning api key without a value is unchanged`() {
        let input = "the api key rotation runs every 24h"
        #expect(LogRedactor.redact(input) == input)
    }

    @Test
    func `key equals in prose without url marker is unchanged`() {
        let input = "primary key=abc123 lookup failed"
        #expect(LogRedactor.redact(input) == input)
    }
}
