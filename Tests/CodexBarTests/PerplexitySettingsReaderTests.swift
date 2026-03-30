import Testing
@testable import CodexBarCore

struct PerplexitySettingsReaderTests {
    @Test
    func `PERPLEXITY_COOKIE preserves the original supported cookie name`() {
        let override = PerplexitySettingsReader.sessionCookieOverride(environment: [
            "PERPLEXITY_COOKIE": "authjs.session-token=env-token",
        ])

        #expect(override?.name == "authjs.session-token")
        #expect(override?.token == "env-token")
        #expect(PerplexitySettingsReader.sessionToken(environment: [
            "PERPLEXITY_COOKIE": "authjs.session-token=env-token",
        ]) == "env-token")
    }

    @Test
    func `PERPLEXITY_COOKIE reassembles chunked session cookies`() {
        let override = PerplexitySettingsReader.sessionCookieOverride(environment: [
            "PERPLEXITY_COOKIE": "authjs.session-token.0=chunk-a; authjs.session-token.1=chunk-b",
        ])

        #expect(override?.name == "authjs.session-token")
        #expect(override?.token == "chunk-achunk-b")
    }

    @Test
    func `PERPLEXITY_SESSION_TOKEN tries all supported cookie names`() {
        let override = PerplexitySettingsReader.sessionCookieOverride(environment: [
            "PERPLEXITY_SESSION_TOKEN": "env-token",
        ])

        #expect(override?.name == PerplexityCookieHeader.defaultSessionCookieName)
        #expect(override?.token == "env-token")
        #expect(override?.requestCookieNames == PerplexityCookieHeader.supportedSessionCookieNames)
    }
}
