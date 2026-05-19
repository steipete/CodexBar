import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AzureOpenAIUsageFetcherTests {
    @Test
    func `settings reader trims env vars and normalizes endpoint`() throws {
        let environment = [
            AzureOpenAISettingsReader.apiKeyEnvironmentKey: " 'azure-key' ",
            AzureOpenAISettingsReader.endpointEnvironmentKey: "my-resource.openai.azure.com",
            AzureOpenAISettingsReader.deploymentNameEnvironmentKey: " \"chat-deployment\" ",
        ]

        #expect(AzureOpenAISettingsReader.apiKey(environment: environment) == "azure-key")
        #expect(
            AzureOpenAISettingsReader.endpoint(environment: environment)?.absoluteString ==
                "https://my-resource.openai.azure.com")
        #expect(AzureOpenAISettingsReader.deploymentName(environment: environment) == "chat-deployment")
        #expect(AzureOpenAISettingsReader.apiVersion(environment: [:]) == AzureOpenAISettingsReader.defaultAPIVersion)
    }

    @Test
    func `fetcher validates deployment with chat completions request`() async throws {
        let endpoint = try #require(URL(string: "https://example-resource.openai.azure.com"))
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/openai/deployments/chat-prod/chat/completions")
            #expect(request.url?.query == "api-version=2024-10-21")
            #expect(request.value(forHTTPHeaderField: "api-key") == "azure-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["max_tokens"] as? Int == 1)
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages.first?["content"] == "ping")

            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"id":"cmpl-1","model":"gpt-4o-mini"}"#.utf8), response)
        }

        let snapshot = try await AzureOpenAIUsageFetcher.fetchUsage(
            apiKey: "azure-key",
            endpoint: endpoint,
            deploymentName: "chat-prod",
            transport: transport,
            updatedAt: updatedAt)

        #expect(snapshot.endpointHost == "example-resource.openai.azure.com")
        #expect(snapshot.deploymentName == "chat-prod")
        #expect(snapshot.model == "gpt-4o-mini")
        #expect(snapshot.apiVersion == AzureOpenAISettingsReader.defaultAPIVersion)
        #expect(snapshot.updatedAt == updatedAt)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.identity?.providerID == .azureopenai)
        #expect(usage.identity?.accountOrganization == "example-resource.openai.azure.com")
        #expect(usage.identity?.loginMethod == "Deployment: chat-prod")
        #expect(usage.primary?.resetDescription == "Deployment: chat-prod · Model: gpt-4o-mini")
    }

    @Test
    func `chat completions URL preserves endpoint path and deployment escaping`() throws {
        let endpoint = try #require(URL(string: "https://proxy.example.com/base"))
        let url = try AzureOpenAIUsageFetcher._chatCompletionsURLForTesting(
            endpoint: endpoint,
            deploymentName: "chat prod",
            apiVersion: "2024-10-21")

        #expect(
            url.absoluteString ==
                "https://proxy.example.com/base/openai/deployments/chat%20prod/chat/completions?api-version=2024-10-21")
    }

    @Test
    func `v1 API validates with OpenAI compatible path and model field`() async throws {
        let endpoint = try #require(URL(string: "https://example-resource.openai.azure.com"))
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.httpMethod == "POST")
            #expect(
                request.url?.absoluteString ==
                    "https://example-resource.openai.azure.com/openai/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "api-key") == "azure-key")

            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "chat-prod")
            #expect(json["max_completion_tokens"] as? Int == 1)
            #expect(json["max_tokens"] == nil)

            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"id":"cmpl-1","model":"gpt-4o-mini"}"#.utf8), response)
        }

        let snapshot = try await AzureOpenAIUsageFetcher.fetchUsage(
            apiKey: "azure-key",
            endpoint: endpoint,
            deploymentName: "chat-prod",
            apiVersion: "v1",
            transport: transport)

        #expect(snapshot.apiVersion == "v1")
        #expect(snapshot.deploymentName == "chat-prod")
        #expect(snapshot.model == "gpt-4o-mini")
    }
}

@MainActor
struct AzureOpenAIMenuDescriptorTests {
    @Test
    func `azure openai deployment detail appears in menu`() throws {
        let suite = "AzureOpenAIMenuDescriptorTests-menu"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = AzureOpenAIUsageSnapshot(
            endpointHost: "example-resource.openai.azure.com",
            deploymentName: "chat-prod",
            model: "gpt-4o-mini",
            apiVersion: "2024-10-21",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        store._setSnapshotForTesting(snapshot.toUsageSnapshot(), provider: .azureopenai)

        let descriptor = MenuDescriptor.build(
            provider: .azureopenai,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains("Azure OpenAI"))
        #expect(lines.contains("Deployment: chat-prod · Model: gpt-4o-mini"))
    }
}
