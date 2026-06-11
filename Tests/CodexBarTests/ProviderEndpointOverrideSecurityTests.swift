import CodexBarCore
import Foundation
import Testing

struct ProviderEndpointOverrideSecurityTests {
    @Test
    func `sibling endpoint overrides reject userinfo and encoded host delimiters`() {
        let userInfoURL = "https://user:pass@proxy.test/v1"
        let encodedHostURL = "https://proxy.test%2f.attacker.test/v1"

        #expect(OpenRouterSettingsReader.apiURL(
            environment: ["OPENROUTER_API_URL": userInfoURL]).host == "openrouter.ai")
        #expect(throws: OpenRouterSettingsError.invalidEndpointOverride("OPENROUTER_API_URL")) {
            try OpenRouterSettingsReader.validateEndpointOverrides(
                environment: ["OPENROUTER_API_URL": encodedHostURL])
        }

        #expect(CodebuffSettingsReader.apiURL(
            environment: ["CODEBUFF_API_URL": userInfoURL]).host == "www.codebuff.com")
        #expect(throws: CodebuffSettingsError.invalidEndpointOverride("CODEBUFF_API_URL")) {
            try CodebuffSettingsReader.validateEndpointOverrides(
                environment: ["CODEBUFF_API_URL": encodedHostURL])
        }

        #expect(GroqSettingsReader.apiURL(
            environment: [GroqSettingsReader.apiURLEnvironmentKey: userInfoURL]).host == "api.groq.com")
        #expect(throws: GroqSettingsError.invalidEndpointOverride(GroqSettingsReader.apiURLEnvironmentKey)) {
            try GroqSettingsReader.validateEndpointOverrides(
                environment: [GroqSettingsReader.apiURLEnvironmentKey: encodedHostURL])
        }

        #expect(ElevenLabsSettingsReader.apiURL(
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: userInfoURL]).host == "api.elevenlabs.io")
        #expect(throws: ElevenLabsSettingsError.invalidEndpointOverride(
            ElevenLabsSettingsReader.apiURLEnvironmentKey))
        {
            try ElevenLabsSettingsReader.validateEndpointOverrides(
                environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: encodedHostURL])
        }
    }

    @Test
    func `OpenRouter endpoint override must be HTTPS or a bare host`() throws {
        let httpsURL = OpenRouterSettingsReader.apiURL(
            environment: ["OPENROUTER_API_URL": "https://router.test/v1"])
        #expect(httpsURL.absoluteString == "https://router.test/v1")

        let bareURL = OpenRouterSettingsReader.apiURL(environment: ["OPENROUTER_API_URL": "router.test/v1"])
        #expect(bareURL.absoluteString == "https://router.test/v1")

        let hostPortURL = OpenRouterSettingsReader.apiURL(
            environment: ["OPENROUTER_API_URL": "localhost:8080/v1"])
        #expect(hostPortURL.absoluteString == "https://localhost:8080/v1")

        let httpURL = OpenRouterSettingsReader.apiURL(
            environment: ["OPENROUTER_API_URL": "http://attacker.test/v1"])
        #expect(httpURL.absoluteString == "https://openrouter.ai/api/v1")

        do {
            try OpenRouterSettingsReader.validateEndpointOverrides(
                environment: ["OPENROUTER_API_URL": "http://attacker.test/v1"])
            Issue.record("Expected OpenRouterSettingsError.invalidEndpointOverride")
        } catch OpenRouterSettingsError.invalidEndpointOverride("OPENROUTER_API_URL") {
            // Expected.
        } catch {
            Issue.record("Expected OpenRouterSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func `Codebuff endpoint override must be HTTPS or a bare host`() throws {
        let httpsURL = CodebuffSettingsReader.apiURL(environment: ["CODEBUFF_API_URL": "https://codebuff.test"])
        #expect(httpsURL.absoluteString == "https://codebuff.test")

        let bareURL = CodebuffSettingsReader.apiURL(environment: ["CODEBUFF_API_URL": "codebuff.test"])
        #expect(bareURL.absoluteString == "https://codebuff.test")

        let hostPortURL = CodebuffSettingsReader.apiURL(environment: ["CODEBUFF_API_URL": "localhost:8080"])
        #expect(hostPortURL.absoluteString == "https://localhost:8080")

        let httpURL = CodebuffSettingsReader.apiURL(environment: ["CODEBUFF_API_URL": "http://attacker.test"])
        #expect(httpURL.absoluteString == "https://www.codebuff.com")

        do {
            try CodebuffSettingsReader.validateEndpointOverrides(
                environment: ["CODEBUFF_API_URL": "http://attacker.test"])
            Issue.record("Expected CodebuffSettingsError.invalidEndpointOverride")
        } catch CodebuffSettingsError.invalidEndpointOverride("CODEBUFF_API_URL") {
            // Expected.
        } catch {
            Issue.record("Expected CodebuffSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func `Groq endpoint override must be HTTPS or a bare host`() throws {
        let httpsURL = GroqSettingsReader.apiURL(
            environment: [GroqSettingsReader.apiURLEnvironmentKey: "https://groq.test/v1"])
        #expect(httpsURL.absoluteString == "https://groq.test/v1")

        let bareURL = GroqSettingsReader.apiURL(
            environment: [GroqSettingsReader.apiURLEnvironmentKey: "groq.test/v1"])
        #expect(bareURL.absoluteString == "https://groq.test/v1")

        let hostPortURL = GroqSettingsReader.apiURL(
            environment: [GroqSettingsReader.apiURLEnvironmentKey: "localhost:8080/v1"])
        #expect(hostPortURL.absoluteString == "https://localhost:8080/v1")

        let httpURL = GroqSettingsReader.apiURL(
            environment: [GroqSettingsReader.apiURLEnvironmentKey: "http://attacker.test/v1"])
        #expect(httpURL.absoluteString == "https://api.groq.com/v1")

        do {
            try GroqSettingsReader.validateEndpointOverrides(
                environment: [GroqSettingsReader.apiURLEnvironmentKey: "http://attacker.test/v1"])
            Issue.record("Expected GroqSettingsError.invalidEndpointOverride")
        } catch GroqSettingsError.invalidEndpointOverride(GroqSettingsReader.apiURLEnvironmentKey) {
            // Expected.
        } catch {
            Issue.record("Expected GroqSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func `ElevenLabs endpoint override must be HTTPS or a bare host`() throws {
        let httpsURL = ElevenLabsSettingsReader.apiURL(
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "https://eleven.test"])
        #expect(httpsURL.absoluteString == "https://eleven.test")

        let bareURL = ElevenLabsSettingsReader.apiURL(
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "eleven.test"])
        #expect(bareURL.absoluteString == "https://eleven.test")

        let hostPortURL = ElevenLabsSettingsReader.apiURL(
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "localhost:8080"])
        #expect(hostPortURL.absoluteString == "https://localhost:8080")

        let httpURL = ElevenLabsSettingsReader.apiURL(
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "http://attacker.test"])
        #expect(httpURL.absoluteString == "https://api.elevenlabs.io")

        do {
            try ElevenLabsSettingsReader.validateEndpointOverrides(
                environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "http://attacker.test"])
            Issue.record("Expected ElevenLabsSettingsError.invalidEndpointOverride")
        } catch ElevenLabsSettingsError.invalidEndpointOverride(ElevenLabsSettingsReader.apiURLEnvironmentKey) {
            // Expected.
        } catch {
            Issue.record("Expected ElevenLabsSettingsError.invalidEndpointOverride, got \(error)")
        }
    }
}
