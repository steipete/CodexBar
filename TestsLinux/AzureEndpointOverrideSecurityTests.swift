import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite
struct AzureEndpointOverrideSecurityTests {
    @Test
    func azureOpenAIEndpointOverrideMustBeHTTPSOrBareHost() throws {
        let httpsURL = try #require(AzureOpenAISettingsReader.endpointURL(from: "https://proxy.example.com/base"))
        #expect(httpsURL.absoluteString == "https://proxy.example.com/base")

        let bareURL = try #require(AzureOpenAISettingsReader.endpointURL(from: "resource.openai.azure.com"))
        #expect(bareURL.absoluteString == "https://resource.openai.azure.com")

        let hostPortURL = try #require(AzureOpenAISettingsReader.endpointURL(from: "localhost:8443/openai"))
        #expect(hostPortURL.absoluteString == "https://localhost:8443/openai")

        let trimmedURL = try #require(AzureOpenAISettingsReader.endpointURL(from: " https://trimmed.example.com/base "))
        #expect(trimmedURL.absoluteString == "https://trimmed.example.com/base")

        #expect(AzureOpenAISettingsReader.endpointURL(from: "http://attacker.test") == nil)
        #expect(AzureOpenAISettingsReader.endpointURL(from: "https://user:pass@proxy.example.com") == nil)
        #expect(AzureOpenAISettingsReader.endpointURL(from: "https://proxy.example.com%2f.attacker.test") == nil)

        #expect(throws: AzureOpenAISettingsError.invalidEndpointOverride(
            AzureOpenAISettingsReader.endpointEnvironmentKey))
        {
            try AzureOpenAISettingsReader.validateEndpointOverrides(environment: [
                AzureOpenAISettingsReader.endpointEnvironmentKey: "http://attacker.test",
            ])
        }
    }

    @Test
    func azureOpenAIHTTPOverrideIsRejectedBeforeAPIKeyRequest() async throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:31337"))
        let transport = CapturingTransport { request in
            Issue.record("Azure OpenAI should reject insecure endpoint overrides before sending api-key headers")
            #expect(request.value(forHTTPHeaderField: "api-key") == nil)
            throw CapturingTransportError.unexpectedRequest
        }

        do {
            _ = try await AzureOpenAIUsageFetcher.fetchUsage(
                apiKey: "AZURE_CANARY_KEY",
                endpoint: endpoint,
                deploymentName: "canary-deployment",
                transport: transport,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
            Issue.record("Expected AzureOpenAIUsageError.invalidEndpointOverride")
        } catch {
            #expect(error as? AzureOpenAIUsageError == .invalidEndpointOverride(
                AzureOpenAISettingsReader.endpointEnvironmentKey))
        }
    }
}

private enum CapturingTransportError: Error {
    case unexpectedRequest
}

private struct CapturingTransport: ProviderHTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.handler(request)
    }
}
