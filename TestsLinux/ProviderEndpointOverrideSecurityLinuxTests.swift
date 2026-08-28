import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct ProviderEndpointOverrideSecurityLinuxTests {
    @Test
    func `mimo invalid endpoint override does not fallback to local cache`() {
        #expect(MiMoWebFetchStrategy.shouldFallbackToLocal(
            error: MiMoSettingsError.invalidEndpointOverride(MiMoSettingsReader.apiURLKey)) == false)
        #expect(MiMoWebFetchStrategy.shouldFallbackToLocal(error: MiMoSettingsError.missingCookie()) == true)
        #expect(MiMoWebFetchStrategy.shouldFallbackToLocal(error: MiMoSettingsError.invalidCookie) == true)
    }

    #if !canImport(CQuickJS)
    @Test
    func `deepgram rejects insecure override before sending token`() async {
        let transport = FailingTransport()
        do {
            _ = try await DeepgramUsageFetcher.fetchUsage(
                apiKey: "dg-test-token",
                environment: [DeepgramUsageFetcher.apiURLKey: "http://attacker.test/v1"],
                transport: transport)
            Issue.record("Expected DeepgramUsageError.invalidEndpointOverride")
        } catch DeepgramUsageError.invalidEndpointOverride(DeepgramUsageFetcher.apiURLKey) {
            // Expected.
        } catch {
            Issue.record("Expected DeepgramUsageError.invalidEndpointOverride, got \(error)")
        }
    }
    #endif

    @Test
    func `zai rejects insecure quota override before sending token`() {
        #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.quotaURLKey)) {
            try ZaiSettingsReader.validateEndpointOverrides(
                environment: [ZaiSettingsReader.quotaURLKey: "http://attacker.test/quota"])
        }
    }

    @Test
    func `zai rejects insecure API host override when quota URL is absent`() {
        #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.apiHostKey)) {
            try ZaiSettingsReader.validateEndpointOverrides(
                environment: [ZaiSettingsReader.apiHostKey: "http://attacker.test"])
        }
    }

    @Test
    func `zai quota resolution ignores invalid lower priority API host`() throws {
        let environment = [
            ZaiSettingsReader.quotaURLKey: "https://zai-proxy.test/quota",
            ZaiSettingsReader.apiHostKey: "http://attacker.test",
        ]

        try ZaiSettingsReader.validateQuotaEndpointOverride(environment: environment)
        #expect(ZaiEndpointRouter.resolveQuotaURL(region: .global, environment: environment).absoluteString ==
            "https://zai-proxy.test/quota")
    }

    @Test
    func `zai combined validation rejects invalid API host before quota request`() {
        let environment = [
            ZaiSettingsReader.quotaURLKey: "https://127.0.0.1:31337/quota",
            ZaiSettingsReader.apiHostKey: "http://127.0.0.1:31337",
        ]

        #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.apiHostKey)) {
            try ZaiSettingsReader.validateEndpointOverrides(environment: environment)
        }
    }

    @Test
    func `zai model usage rejects insecure API host override`() {
        #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.apiHostKey)) {
            try ZaiSettingsReader.validateAPIHostEndpointOverride(
                environment: [ZaiSettingsReader.apiHostKey: "http://attacker.test"])
        }
    }

    @Test
    func `mimo rejects insecure override before sending cookie`() async {
        let transport = FailingTransport()
        do {
            _ = try await MiMoUsageFetcher.fetchUsage(
                cookieHeader: "api-platform_serviceToken=session-token; userId=user-1",
                environment: [MiMoSettingsReader.apiURLKey: "http://attacker.test/api/v1"],
                session: transport)
            Issue.record("Expected MiMoSettingsError.invalidEndpointOverride")
        } catch MiMoSettingsError.invalidEndpointOverride(MiMoSettingsReader.apiURLKey) {
            // Expected.
        } catch {
            Issue.record("Expected MiMoSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func `affected provider overrides accept HTTPS and bare hosts`() throws {
        #if !canImport(CQuickJS)
        try DeepgramUsageFetcher.validateEndpointOverrides(environment: [
            DeepgramUsageFetcher.apiURLKey: "deepgram-proxy.test/v1",
        ])
        #endif
        try ZaiSettingsReader
            .validateEndpointOverrides(environment: [ZaiSettingsReader.quotaURLKey: "https://zai-proxy.test/quota"])
        try ZaiSettingsReader.validateEndpointOverrides(environment: [ZaiSettingsReader.apiHostKey: "localhost:9443"])
        try MiMoSettingsReader
            .validateEndpointOverrides(environment: [MiMoSettingsReader.apiURLKey: "mimo-proxy.test/api/v1"])

        #expect(ZaiSettingsReader.quotaURL(environment: [ZaiSettingsReader.quotaURLKey: "zai-proxy.test/quota"])?
            .absoluteString == "https://zai-proxy.test/quota")
        #expect(MiMoSettingsReader.apiURL(environment: [MiMoSettingsReader.apiURLKey: "mimo-proxy.test/api/v1"])
            .absoluteString == "https://mimo-proxy.test/api/v1")
    }

    // MARK: - LiteLLM / LLM Proxy

    // Both send their API key to the configured base URL as a bearer token. HTTPS works everywhere;
    // HTTP is limited to loopback and explicitly private-network destinations.

    @Test
    func `lite LLM rejects remote HTTP base URL before sending key`() {
        for endpoint in Self.publicHTTPEndpoints {
            #expect(LiteLLMSettingsReader.baseURL(
                environment: [LiteLLMSettingsReader.baseURLEnvironmentKey: endpoint]) == nil)
        }
    }

    @Test
    func `lite LLM rejects base URL with embedded credentials`() {
        #expect(LiteLLMSettingsReader.baseURL(
            environment: [LiteLLMSettingsReader.baseURLEnvironmentKey: "https://user@attacker.test"]) == nil)
    }

    @Test
    func `lite LLM accepts HTTPS and private network HTTP base UR ls`() {
        #expect(LiteLLMSettingsReader.baseURL(
            environment: [LiteLLMSettingsReader.baseURLEnvironmentKey: "https://litellm.example.com"])?
            .absoluteString == "https://litellm.example.com")
        for endpoint in Self.privateHTTPEndpoints {
            #expect(LiteLLMSettingsReader.baseURL(
                environment: [LiteLLMSettingsReader.baseURLEnvironmentKey: endpoint])?.absoluteString == endpoint)
        }
    }

    @Test
    func `llm proxy rejects remote HTTP base URL before sending key`() {
        for endpoint in Self.publicHTTPEndpoints {
            #expect(LLMProxySettingsReader.baseURL(
                environment: [LLMProxySettingsReader.baseURLEnvironmentKey: endpoint]) == nil)
        }
    }

    @Test
    func `llm proxy rejects base URL with embedded credentials`() {
        #expect(LLMProxySettingsReader.baseURL(
            environment: [LLMProxySettingsReader.baseURLEnvironmentKey: "https://user@attacker.test"]) == nil)
    }

    @Test
    func `rejected base URL stays configured so the error can surface`() {
        // A rejected override must not read as "never configured": the strategy stays available so
        // the fetch path can report invalidEndpointOverride instead of the provider going missing.
        let liteLLM = [LiteLLMSettingsReader.baseURLEnvironmentKey: "http://attacker.test"]
        #expect(LiteLLMSettingsReader.baseURL(environment: liteLLM) == nil)
        #expect(LiteLLMSettingsReader.hasBaseURLOverride(environment: liteLLM))
        #expect(!LiteLLMSettingsReader.hasBaseURLOverride(environment: [:]))

        let llmProxy = [LLMProxySettingsReader.baseURLEnvironmentKey: "http://attacker.test"]
        #expect(LLMProxySettingsReader.baseURL(environment: llmProxy) == nil)
        #expect(LLMProxySettingsReader.hasBaseURLOverride(environment: llmProxy))
        #expect(!LLMProxySettingsReader.hasBaseURLOverride(environment: [:]))
    }

    @Test
    func `rejected override error names the setting and the rule`() {
        // The message has to tell the user which key to fix and what shape is accepted.
        let liteLLM = LiteLLMUsageError
            .invalidEndpointOverride(LiteLLMSettingsReader.baseURLEnvironmentKey).errorDescription ?? ""
        #expect(liteLLM.contains("LITELLM_BASE_URL"))
        #expect(liteLLM.contains("HTTPS"))
        #expect(liteLLM.contains("private-network"))
        #expect(liteLLM.contains(".local"))

        let llmProxy = LLMProxyUsageError
            .invalidEndpointOverride(LLMProxySettingsReader.baseURLEnvironmentKey).errorDescription ?? ""
        #expect(llmProxy.contains("LLM_PROXY_BASE_URL"))
        #expect(llmProxy.contains("HTTPS"))
        #expect(llmProxy.contains("private-network"))
        #expect(llmProxy.contains(".local"))
    }

    @Test
    func `llm proxy accepts HTTPS and private network HTTP base UR ls`() {
        #expect(LLMProxySettingsReader.baseURL(
            environment: [LLMProxySettingsReader.baseURLEnvironmentKey: "https://proxy.example.com"])?
            .absoluteString == "https://proxy.example.com")
        for endpoint in Self.privateHTTPEndpoints {
            #expect(LLMProxySettingsReader.baseURL(
                environment: [LLMProxySettingsReader.baseURLEnvironmentKey: endpoint])?.absoluteString == endpoint)
        }
    }

    @Test
    func `shared loopback only validator still rejects private network HTTP`() {
        let validator = ProviderEndpointOverrideValidator()
        #expect(validator.validatedURLAllowingLoopbackHTTP("http://127.0.0.1:4000") != nil)
        #expect(validator.validatedURLAllowingLoopbackHTTP("http://192.168.1.10:4000") == nil)
        #expect(validator.validatedURLAllowingLoopbackHTTP("http://[fd00::1]:4000") == nil)
        #expect(validator.validatedURLAllowingLoopbackHTTP("http://proxy.local:4000") == nil)
    }

    private static let privateHTTPEndpoints = [
        "http://localhost:4000",
        "http://127.0.0.1:4000",
        "http://[::1]:4000",
        "http://10.255.255.255:4000",
        "http://172.16.0.1:4000",
        "http://172.31.255.255:4000",
        "http://192.168.1.10:4000",
        "http://169.254.10.20:4000",
        "http://[fc00::1]:4000",
        "http://[fdff:ffff::1]:4000",
        "http://[fe80::1]:4000",
        "http://[febf:ffff::1]:4000",
        "http://proxy.local:4000",
        "http://proxy.local.:4000",
    ]

    private static let publicHTTPEndpoints = [
        "http://attacker.test:4000",
        "http://8.8.8.8:4000",
        "http://172.15.255.255:4000",
        "http://172.32.0.0:4000",
        "http://169.253.255.255:4000",
        "http://192.169.0.1:4000",
        "http://[2606:4700:4700::1111]:4000",
        "http://[fec0::1]:4000",
    ]
}

private struct FailingTransport: ProviderHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        Issue
            .record(
                "Endpoint override validation should fail before any request is sent to \(request.url?.absoluteString ?? "<nil>")")
        throw URLError(.badURL)
    }
}
