import CodexBarCore
import Foundation
import Testing

struct ProviderEndpointOverrideSecurityTests {
    @Test
    func `sibling endpoint overrides allow bracketed IPv6 literals`() throws {
        let endpoint = "https://[::1]:8443/v1"

        try OpenRouterSettingsReader.validateEndpointOverrides(
            environment: ["OPENROUTER_API_URL": endpoint])
        #expect(OpenRouterSettingsReader.apiURL(
            environment: ["OPENROUTER_API_URL": endpoint]).absoluteString == endpoint)

        try CodebuffSettingsReader.validateEndpointOverrides(
            environment: ["CODEBUFF_API_URL": endpoint])
        #expect(CodebuffSettingsReader.apiURL(
            environment: ["CODEBUFF_API_URL": endpoint]).absoluteString == endpoint)

        try GroqSettingsReader.validateEndpointOverrides(
            environment: [GroqSettingsReader.apiURLEnvironmentKey: endpoint])
        #expect(GroqSettingsReader.apiURL(
            environment: [GroqSettingsReader.apiURLEnvironmentKey: endpoint]).absoluteString == endpoint)

        try ElevenLabsSettingsReader.validateEndpointOverrides(
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: endpoint])
        #expect(ElevenLabsSettingsReader.apiURL(
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: endpoint]).absoluteString == endpoint)
    }

    @Test
    func `sibling endpoint overrides reject userinfo and encoded host delimiters`() {
        let userInfoURL = "https://user:pass@proxy.test/v1"
        let malformedHostURLs = [
            "https://proxy.test%2f.attacker.test/v1",
            "https://bad host/v1",
            "https://bad%20host/v1",
            "https://bad%09host/v1",
        ]

        #expect(OpenRouterSettingsReader.apiURL(
            environment: ["OPENROUTER_API_URL": userInfoURL]).host == "openrouter.ai")
        for malformedHostURL in malformedHostURLs {
            #expect(throws: OpenRouterSettingsError.invalidEndpointOverride("OPENROUTER_API_URL")) {
                try OpenRouterSettingsReader.validateEndpointOverrides(
                    environment: ["OPENROUTER_API_URL": malformedHostURL])
            }
        }

        #expect(CodebuffSettingsReader.apiURL(
            environment: ["CODEBUFF_API_URL": userInfoURL]).host == "www.codebuff.com")
        for malformedHostURL in malformedHostURLs {
            #expect(throws: CodebuffSettingsError.invalidEndpointOverride("CODEBUFF_API_URL")) {
                try CodebuffSettingsReader.validateEndpointOverrides(
                    environment: ["CODEBUFF_API_URL": malformedHostURL])
            }
        }

        #expect(GroqSettingsReader.apiURL(
            environment: [GroqSettingsReader.apiURLEnvironmentKey: userInfoURL]).host == "api.groq.com")
        for malformedHostURL in malformedHostURLs {
            #expect(throws: GroqSettingsError.invalidEndpointOverride(GroqSettingsReader.apiURLEnvironmentKey)) {
                try GroqSettingsReader.validateEndpointOverrides(
                    environment: [GroqSettingsReader.apiURLEnvironmentKey: malformedHostURL])
            }
        }

        #expect(ElevenLabsSettingsReader.apiURL(
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: userInfoURL]).host == "api.elevenlabs.io")
        for malformedHostURL in malformedHostURLs {
            #expect(throws: ElevenLabsSettingsError.invalidEndpointOverride(
                ElevenLabsSettingsReader.apiURLEnvironmentKey))
            {
                try ElevenLabsSettingsReader.validateEndpointOverrides(
                    environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: malformedHostURL])
            }
        }
    }

    @Test
    func `credentialed fetchers reject insecure overrides before sending requests`() async {
        let insecureURL = "http://attacker.test/v1"

        do {
            _ = try await OpenRouterUsageFetcher.fetchUsage(
                apiKey: "openrouter-test",
                environment: ["OPENROUTER_API_URL": insecureURL])
            Issue.record("Expected OpenRouterSettingsError.invalidEndpointOverride")
        } catch {
            #expect(error as? OpenRouterSettingsError == .invalidEndpointOverride("OPENROUTER_API_URL"))
        }

        do {
            _ = try await CodebuffUsageFetcher.fetchUsage(
                apiKey: "codebuff-test",
                environment: ["CODEBUFF_API_URL": insecureURL])
            Issue.record("Expected CodebuffSettingsError.invalidEndpointOverride")
        } catch {
            #expect(error as? CodebuffSettingsError == .invalidEndpointOverride("CODEBUFF_API_URL"))
        }

        do {
            _ = try await GroqUsageFetcher.fetchUsage(
                apiKey: "groq-test",
                environment: [GroqSettingsReader.apiURLEnvironmentKey: insecureURL])
            Issue.record("Expected GroqSettingsError.invalidEndpointOverride")
        } catch {
            #expect(error as? GroqSettingsError == .invalidEndpointOverride(GroqSettingsReader.apiURLEnvironmentKey))
        }

        do {
            _ = try await ElevenLabsUsageFetcher.fetchUsage(
                apiKey: "elevenlabs-test",
                environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: insecureURL])
            Issue.record("Expected ElevenLabsSettingsError.invalidEndpointOverride")
        } catch {
            #expect(error as? ElevenLabsSettingsError == .invalidEndpointOverride(
                ElevenLabsSettingsReader.apiURLEnvironmentKey))
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
