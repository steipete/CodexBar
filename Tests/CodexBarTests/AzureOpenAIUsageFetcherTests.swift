import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AzureOpenAIUsageFetcherTests {
    private func makeContext(environment: [String: String]) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `settings reader trims env vars and normalizes endpoint`() {
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
    func `missing deployment config returns precise provider error`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .azureopenai)
        let outcome = await descriptor.fetchPlan.fetchOutcome(
            context: self.makeContext(environment: [
                AzureOpenAISettingsReader.apiKeyEnvironmentKey: "azure-key",
                AzureOpenAISettingsReader.endpointEnvironmentKey: "https://example-resource.openai.azure.com",
            ]),
            provider: .azureopenai)

        guard case let .failure(error) = outcome.result else {
            Issue.record("Expected missing deployment to fail")
            return
        }

        #expect(error as? AzureOpenAIUsageError == .missingDeploymentName)
        #expect(error.localizedDescription.contains("deployment not configured"))
        #expect(outcome.attempts.map(\.wasAvailable) == [true])
    }

    @Test
    func `invalid endpoint returns precise provider error before fetch`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .azureopenai)
        let outcome = await descriptor.fetchPlan.fetchOutcome(
            context: self.makeContext(environment: [
                AzureOpenAISettingsReader.apiKeyEnvironmentKey: "AZURE_CANARY_KEY",
                AzureOpenAISettingsReader.endpointEnvironmentKey: "http://127.0.0.1:31337",
                AzureOpenAISettingsReader.deploymentNameEnvironmentKey: "canary-deployment",
            ]),
            provider: .azureopenai)

        guard case let .failure(error) = outcome.result else {
            Issue.record("Expected invalid endpoint override to fail")
            return
        }

        #expect(error as? AzureOpenAISettingsError == .invalidEndpointOverride(
            AzureOpenAISettingsReader.endpointEnvironmentKey))
        #expect(error.localizedDescription.contains("HTTPS endpoint"))
        #expect(outcome.attempts.map(\.wasAvailable) == [true])
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
            #expect(json["max_completion_tokens"] == nil)
            #expect(json["temperature"] == nil)
            #expect(json["reasoning_effort"] == nil)
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
    func `chat completions URL does not duplicate openai endpoint suffix`() throws {
        let endpoint = try #require(URL(string: "https://proxy.example.com/base/openai"))
        let url = try AzureOpenAIUsageFetcher._chatCompletionsURLForTesting(
            endpoint: endpoint,
            deploymentName: "chat-prod",
            apiVersion: "2024-10-21")

        #expect(
            url.absoluteString ==
                "https://proxy.example.com/base/openai/deployments/chat-prod/chat/completions?api-version=2024-10-21")
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
            let completionCap = try #require(json["max_completion_tokens"] as? Int)
            #expect(completionCap == 64)
            #expect(completionCap <= 64)
            #expect(json["max_tokens"] == nil)
            #expect(json["temperature"] == nil)
            #expect(json["reasoning_effort"] == nil)

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

    @Test
    func `v1 API accepts documented openai v1 base URL`() throws {
        let endpoint = try #require(URL(string: "https://example-resource.openai.azure.com/openai/v1"))
        let url = try AzureOpenAIUsageFetcher._chatCompletionsURLForTesting(
            endpoint: endpoint,
            deploymentName: "chat-prod",
            apiVersion: "v1")

        #expect(
            url.absoluteString ==
                "https://example-resource.openai.azure.com/openai/v1/chat/completions")
    }
}

@MainActor
struct AzureOpenAIProviderAvailabilityTests {
    @Test
    func `configured invalid endpoint remains visible for actionable error`() throws {
        let suite = "AzureOpenAIProviderAvailabilityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.azureOpenAIAPIKey = "AZURE_CANARY_KEY"
        settings.azureOpenAIEndpoint = "http://127.0.0.1:31337"
        settings.azureOpenAIDeploymentName = "canary-deployment"

        let environment = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .azureopenai,
            settings: settings,
            tokenOverride: nil)
        let context = ProviderAvailabilityContext(
            provider: .azureopenai,
            settings: settings,
            environment: environment)

        #expect(AzureOpenAISettingsReader.endpoint(environment: environment) == nil)
        #expect(AzureOpenAIProviderImplementation().isAvailable(context: context))
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

struct AzureOpenAISettingsTests {
    @Test(arguments: [
        (nil as String?, nil as String?, "2024-10-21"),
        (nil, "v1", "v1"),
        ("v1", nil, "v1"),
        ("v1", "2024-10-21", "v1"),
        ("2024-10-21", "v1", "2024-10-21"),
        ("  ", "v1", "v1"),
        (" \"v1\" ", "2024-10-21", "v1"),
        ("custom &version=#value", "v1", "custom &version=#value"),
    ])
    func `config version precedence reaches the expected request`(
        configured: String?, environmentVersion: String?, expected: String) async throws
    {
        var config = ProviderConfig(id: .azureopenai)
        config.azureOpenAIAPIVersion = configured
        let credentials = try #require(AzureOpenAIProviderDescriptor.descriptor.credentials)
        var base: [String: String] = [:]
        base[AzureOpenAISettingsReader.apiVersionEnvironmentKey] = environmentVersion
        let environment = credentials.applyConfig(base: base, config: config)
        let version = AzureOpenAISettingsReader.apiVersion(environment: environment)
        #expect(version == expected)

        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "example-resource.openai.azure.com")
            #expect(url.fragment == nil)
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            if expected == "v1" {
                #expect(url.path == "/openai/v1/chat/completions")
                #expect(url.query == nil)
                #expect(json["model"] as? String == "chat-prod")
                #expect(json["max_completion_tokens"] as? Int == 64)
                #expect(json["max_tokens"] == nil)
            } else {
                #expect(url.path == "/openai/deployments/chat-prod/chat/completions")
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                #expect(components.queryItems == [URLQueryItem(name: "api-version", value: expected)])
                #expect(json["max_tokens"] as? Int == 1)
                #expect(json["max_completion_tokens"] == nil)
                #expect(json["model"] == nil)
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"model":"gpt-4o-mini"}"#.utf8), response)
        }
        let snapshot = try await AzureOpenAIUsageFetcher.fetchUsage(
            apiKey: "test-key",
            endpoint: #require(URL(string: "https://example-resource.openai.azure.com")),
            deploymentName: "chat-prod",
            apiVersion: version,
            transport: transport)
        #expect(snapshot.apiVersion == expected)
    }

    @Test
    func `provider config without a version inherits environment version`() throws {
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"id":"azureopenai"}"#.utf8))
        #expect(config.azureOpenAIAPIVersion == nil)
        let credentials = try #require(AzureOpenAIProviderDescriptor.descriptor.credentials)
        let environment = credentials.applyConfig(
            base: [AzureOpenAISettingsReader.apiVersionEnvironmentKey: "v1"], config: config)
        #expect(AzureOpenAISettingsReader.apiVersion(environment: environment) == "v1")
    }

    @Test
    @MainActor
    func `picker persists version and default clears only the version override`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.azureOpenAIAPIKey = "test-key"
        settings.azureOpenAIEndpoint = "https://example-resource.openai.azure.com"
        settings.azureOpenAIDeploymentName = "chat-prod"
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let context = ProviderSettingsContext(
            provider: .azureopenai,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let implementation = AzureOpenAIProviderImplementation()
        let picker = try #require(implementation.settingsPickers(context: context).first)
        #expect(picker.options.map(\.id) == ["", "v1"])
        #expect(picker.binding.wrappedValue.isEmpty)
        picker.binding.wrappedValue = "v1"

        let reader = CodexBarConfigStore(fileURL: settings.configStore.fileURL)
        let saved = try #require(try reader.load())
        #expect(saved.providerConfig(for: .azureopenai)?.azureOpenAIAPIVersion == "v1")
        let reloaded = testSettingsStore(
            suiteName: "azure-version-reloaded", userDefaults: InMemoryUserDefaults(), config: saved)
        #expect(reloaded.azureOpenAIAPIVersion == "v1")
        let environment = ProviderRegistry.makeEnvironment(
            base: [AzureOpenAISettingsReader.apiVersionEnvironmentKey: "2024-10-21"],
            provider: .azureopenai,
            settings: reloaded,
            tokenOverride: nil)
        #expect(AzureOpenAISettingsReader.apiVersion(environment: environment) == "v1")

        settings.azureOpenAIAPIVersion = "2025-01-01-preview"
        #expect(implementation.settingsPickers(context: context).first?.options.last?.id == "2025-01-01-preview")
        picker.binding.wrappedValue = ""
        let cleared = try #require(try reader.load()?.providerConfig(for: .azureopenai))
        #expect(cleared.azureOpenAIAPIVersion == nil)
        #expect(cleared.apiKey == "test-key")
        #expect(cleared.enterpriseHost == "https://example-resource.openai.azure.com")
        #expect(cleared.workspaceID == "chat-prod")
        let defaultEnvironment = ProviderRegistry.makeEnvironment(
            base: [AzureOpenAISettingsReader.apiVersionEnvironmentKey: "v1"],
            provider: .azureopenai,
            settings: settings,
            tokenOverride: nil)
        #expect(AzureOpenAISettingsReader.apiVersion(environment: defaultEnvironment) == "v1")
    }
}
