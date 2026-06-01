import CodexBarCore
import Foundation
import Testing

struct ProviderEndpointOverrideSecurityTests {
    @Test
    func `OpenRouter endpoint override must be HTTPS or a bare host`() throws {
        #expect(OpenRouterSettingsReader.apiURL(environment: ["OPENROUTER_API_URL": "https://router.test/v1"]).absoluteString == "https://router.test/v1")
        #expect(OpenRouterSettingsReader.apiURL(environment: ["OPENROUTER_API_URL": "router.test/v1"]).absoluteString == "https://router.test/v1")
        #expect(OpenRouterSettingsReader.apiURL(environment: ["OPENROUTER_API_URL": "http://attacker.test/v1"]).absoluteString == "https://openrouter.ai/api/v1")

        do {
            try OpenRouterSettingsReader.validateEndpointOverrides(environment: ["OPENROUTER_API_URL": "http://attacker.test/v1"])
            Issue.record("Expected OpenRouterSettingsError.invalidEndpointOverride")
        } catch OpenRouterSettingsError.invalidEndpointOverride("OPENROUTER_API_URL") {
            // Expected.
        } catch {
            Issue.record("Expected OpenRouterSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func `Codebuff endpoint override must be HTTPS or a bare host`() throws {
        #expect(CodebuffSettingsReader.apiURL(environment: ["CODEBUFF_API_URL": "https://codebuff.test"]).absoluteString == "https://codebuff.test")
        #expect(CodebuffSettingsReader.apiURL(environment: ["CODEBUFF_API_URL": "codebuff.test"]).absoluteString == "https://codebuff.test")
        #expect(CodebuffSettingsReader.apiURL(environment: ["CODEBUFF_API_URL": "http://attacker.test"]).absoluteString == "https://www.codebuff.com")

        do {
            try CodebuffSettingsReader.validateEndpointOverrides(environment: ["CODEBUFF_API_URL": "http://attacker.test"])
            Issue.record("Expected CodebuffSettingsError.invalidEndpointOverride")
        } catch CodebuffSettingsError.invalidEndpointOverride("CODEBUFF_API_URL") {
            // Expected.
        } catch {
            Issue.record("Expected CodebuffSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func `Groq endpoint override must be HTTPS or a bare host`() throws {
        #expect(GroqSettingsReader.apiURL(environment: [GroqSettingsReader.apiURLEnvironmentKey: "https://groq.test/v1"]).absoluteString == "https://groq.test/v1")
        #expect(GroqSettingsReader.apiURL(environment: [GroqSettingsReader.apiURLEnvironmentKey: "groq.test/v1"]).absoluteString == "https://groq.test/v1")
        #expect(GroqSettingsReader.apiURL(environment: [GroqSettingsReader.apiURLEnvironmentKey: "http://attacker.test/v1"]).absoluteString == "https://api.groq.com/v1")

        do {
            try GroqSettingsReader.validateEndpointOverrides(environment: [GroqSettingsReader.apiURLEnvironmentKey: "http://attacker.test/v1"])
            Issue.record("Expected GroqSettingsError.invalidEndpointOverride")
        } catch GroqSettingsError.invalidEndpointOverride(GroqSettingsReader.apiURLEnvironmentKey) {
            // Expected.
        } catch {
            Issue.record("Expected GroqSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func `ElevenLabs endpoint override must be HTTPS or a bare host`() throws {
        #expect(ElevenLabsSettingsReader.apiURL(environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "https://eleven.test"]).absoluteString == "https://eleven.test")
        #expect(ElevenLabsSettingsReader.apiURL(environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "eleven.test"]).absoluteString == "https://eleven.test")
        #expect(ElevenLabsSettingsReader.apiURL(environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "http://attacker.test"]).absoluteString == "https://api.elevenlabs.io")

        do {
            try ElevenLabsSettingsReader.validateEndpointOverrides(environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "http://attacker.test"])
            Issue.record("Expected ElevenLabsSettingsError.invalidEndpointOverride")
        } catch ElevenLabsSettingsError.invalidEndpointOverride(ElevenLabsSettingsReader.apiURLEnvironmentKey) {
            // Expected.
        } catch {
            Issue.record("Expected ElevenLabsSettingsError.invalidEndpointOverride, got \(error)")
        }
    }
}
