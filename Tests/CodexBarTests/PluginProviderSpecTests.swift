import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct PluginProviderSpecTests {
    private static let providers: [UsageProvider] = [
        .xkiro,
        .atlascloud,
        .vercel,
        .devpass,
        .gitkraken,
        .poe,
        .deepinfra,
        .zenmux,
        .clinepass,
        .aiand,
        .synthetic, .chutes, .v0, .elevenlabs, .neuralwatt, .clawrouter,
        .aixy, .bifrost, .deepgram, .llmproxy, .litellm, .sub2api, .llmman,
        .helmcode, .hyper, .manus, .perplexity, .qoder, .raycast, .sakana, .t3chat, .museai,
        .huggingface, .nous, .fireworks, .xai, .venice, .zed,
        .tavily, .linkup, .tinyapi, .exa,
    ]

    private static let isolatedEnvironment = [
        "HF_HOME": "/__codexbar_plugin_glue_b4_fixture__/hf",
        "HERMES_HOME": "/__codexbar_plugin_glue_b4_fixture__/hermes",
    ]

    private struct DerivedProvider: Decodable, Equatable {
        let id: String
        let projections: [String: String]
        let sourceModes: [String]
        let strategies: [String]
        let fields: [String]
        let availability: [Bool]
        let environmentAvailability: [[Bool]]
        let supportsTokenCost: Bool
        let enterpriseHost: Bool
        let workspaceOrder: Int?
        let projectToken: String
        let cliResolution: [String: [String]]
    }

    @Test
    func `builders preserve derived registration and settings behavior`() async throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "PluginProviderSpecTests")
        var rows: [DerivedProvider] = []
        for provider in Self.providers {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let fields = implementation.settingsFields(context: fixture.settingsContext(provider: provider))
            let availability = ["", "  ", "fixture-key"].map { value in
                fixture.settings[providerConfig: provider, field: .apiKey] = value
                return implementation.isAvailable(context: .init(
                    provider: provider, settings: fixture.settings, environment: Self.isolatedEnvironment))
            }
            fixture.settings[providerConfig: provider, field: .apiKey] = ""
            var config = ProviderConfig(id: provider.instanceID, apiKey: "fixture-key", workspaceID: "fixture-project")
            config.enterpriseHost = "https://fixture.example.com"
            config.litellmModelUsageEnabled = true
            let projected = descriptor.credentials?.applyConfig(base: [:], config: config) ?? [:]
            let keyOnly = descriptor.credentials?.applyConfig(
                base: [:], config: ProviderConfig(id: provider.instanceID, apiKey: "fixture-key")) ?? [:]
            config.enterpriseHost = "http://public.example.com"
            let invalid = descriptor.credentials?.applyConfig(base: [:], config: config) ?? [:]
            var environmentAvailability: [[Bool]] = []
            for environment in [[:], keyOnly, projected, invalid] {
                let context = ProviderCutoverTestSupport.context(
                    environment: Self.isolatedEnvironment.merging(environment) { _, value in value })
                let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
                await environmentAvailability.append([
                    implementation.isAvailable(context: .init(
                        provider: provider,
                        settings: fixture.settings,
                        environment: Self.isolatedEnvironment.merging(environment) { _, value in value })),
                    strategies.first?.isAvailable(context) ?? false,
                ])
            }
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(ProviderCutoverTestSupport.context())
            let cliResolution = Dictionary(uniqueKeysWithValues: ([descriptor.cli.name] + descriptor.cli.aliases).map {
                ($0.uppercased(), ProviderSelection(argument: $0.uppercased())?.asList.map(\.rawValue) ?? [])
            })
            rows.append(DerivedProvider(
                id: provider.rawValue,
                projections: projected,
                sourceModes: descriptor.fetchPlan.sourceModes.map(\.rawValue).sorted(),
                strategies: strategies.map(\.id),
                fields: fields.map { $0.kind == .secure ? "secure" : "plain" },
                availability: availability,
                environmentAvailability: environmentAvailability,
                supportsTokenCost: descriptor.tokenCost.supportsTokenCost,
                enterpriseHost: descriptor.config.supportsEnterpriseHost,
                workspaceOrder: descriptor.config.workspaceIDValidationOrder,
                projectToken: descriptor.credentials?.resolveToken(kind: .projectID, environment: projected)?
                    .token ?? "",
                cliResolution: cliResolution))
        }
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/plugin-provider-specs.json")
        let expected = try JSONDecoder().decode([DerivedProvider].self, from: Data(contentsOf: golden))
        #expect(rows == expected)
    }

    @Test
    func `API key aliases skip empty values and clean quotes`() {
        let spec = PluginProviderSpec(
            id: .xkiro,
            displayName: "Fixture",
            sessionLabel: "Daily",
            weeklyLabel: "Weekly",
            dashboardURL: "https://example.com",
            color: .init(hex: 0x123456),
            confetti: [0x123456, 0x654321],
            noDataMessage: "No history",
            environmentKey: "FIXTURE_KEY",
            environmentAliases: ["FIXTURE_ALIAS"])
        #expect(spec.apiKey(environment: [:]) == nil)
        #expect(spec.apiKey(environment: ["FIXTURE_KEY": "  ", "FIXTURE_ALIAS": " 'alias' "]) == "alias")
        #expect(spec.apiKey(environment: ["FIXTURE_KEY": " primary ", "FIXTURE_ALIAS": "alias"]) == "primary")
    }

    @Test
    func `pilot pipelines keep their credential boundaries without prototype flags`() async throws {
        let keys: [UsageProvider: String] = [
            .xkiro: "XKIRO_API_KEY",
            .atlascloud: "ATLASCLOUD_API_KEY",
            .vercel: "AI_GATEWAY_API_KEY",
            .devpass: "DEVPASS_API_KEY",
            .gitkraken: "GITKRAKEN_API_TOKEN",
            .poe: "POE_API_KEY",
            .deepinfra: "DEEPINFRA_API_KEY",
            .zenmux: "ZENMUX_MANAGEMENT_API_KEY",
            .clinepass: "CLINE_API_KEY",
            .aiand: "AIAND_API_KEY",
        ]
        for (provider, key) in keys {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let context = ProviderCutoverTestSupport.context(environment: [key: " 'fixture-key' "])
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
            #expect(strategies.map(\.id) == ["\(provider.rawValue).js"])
            let strategy = try #require(strategies.first)
            #expect(await strategy.isAvailable(context))
            #expect(await !strategy.isAvailable(ProviderCutoverTestSupport.context(
                environment: ["OTHER_API_KEY": "fixture-key"])))
            #expect(descriptor.credentials?.resolveToken(environment: context.env)?.token == "fixture-key")
            #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        }
    }

    @Test
    func `custom budgets and settings destinations stay explicit`() {
        #expect(AtlasCloudProviderDescriptor.descriptor.menuBarMetrics == .automaticOnly)
        #expect(VercelProviderDescriptor.descriptor.menuBarMetrics == .automaticOnly)
        #expect(DeepInfraProviderDescriptor.spec.timeout == 145)
        #expect(ZenMuxProviderDescriptor.spec.timeout == 35)
        #expect(DevPassProviderDescriptor.spec.apiKeyField?.action?.url == "https://devpass.llmgateway.io/dashboard")
        #expect(ZenMuxProviderDescriptor.spec.apiKeyField?.action?.url == "https://zenmux.ai/platform/management")
        #expect(AiAndProviderDescriptor.spec.apiKeyField?.action?.url == "https://console.aiand.com")
    }
}

extension PluginProviderSpecTests {
    @Test
    func `workspace bindings and project token resolution remain distinct`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "PluginSpec-workspaces")
        for spec in [V0ProviderDescriptor.spec, DeepgramProviderDescriptor.spec] {
            let workspace = try #require(spec.workspaceField)
            let implementation = try #require(ProviderCatalog.implementation(for: spec.id))
            let field = try #require(implementation.settingsFields(context: fixture.settingsContext(provider: spec.id))
                .first { $0.id == workspace.field.id })
            field.binding.wrappedValue = "fixture-project"
            let config = try #require(fixture.settings.providerConfig(for: spec.id))
            #expect(config.workspaceID == "fixture-project")
            #expect(config.apiKey == nil)
            let environment = spec.makeDescriptor().credentials?.applyConfig(base: [:], config: config) ?? [:]
            #expect(environment[workspace.environmentKey] == "fixture-project")
            let project = spec.makeDescriptor().credentials?.resolveToken(kind: .projectID, environment: environment)
            #expect(project?.token == (workspace.resolvesProjectID ? "fixture-project" : nil))
        }
    }

    @Test
    func `endpoint fields share config projection and retain validation policies`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "PluginSpec-endpoints")
        for spec in [
            AixyProviderDescriptor.spec, BifrostProviderDescriptor.spec, LLMProxyProviderDescriptor.spec,
            LiteLLMProviderDescriptor.spec, Sub2APIProviderDescriptor.spec, LLMManProviderDescriptor.spec,
        ] {
            let endpoint = try #require(spec.endpoint)
            let implementation = try #require(ProviderCatalog.implementation(for: spec.id))
            let fields = implementation.settingsFields(context: fixture.settingsContext(provider: spec.id))
            let field = try #require(fields.first { $0.id == endpoint.field.id })
            field.binding.wrappedValue = "https://fixture.example.com/v1"
            let config = try #require(fixture.settings.providerConfig(for: spec.id))
            #expect(config.enterpriseHost == "https://fixture.example.com/v1")
            let projected = spec.makeDescriptor().credentials?.applyConfig(base: [:], config: config) ?? [:]
            #expect(projected[endpoint.environmentKey] == "https://fixture.example.com/v1")
            #expect(endpoint.url(environment: projected)?.absoluteString == "https://fixture.example.com/v1")
            #expect(endpoint.url(environment: [endpoint.environmentKey: "http://public.example.com"]) == nil)
            #expect(endpoint
                .url(environment: [endpoint.environmentKey: "https://user:password@fixture.example.com"]) == nil)
        }
        #expect(AixyProviderDescriptor.spec.endpoint?.url(environment: [:]) == AixySettingsReader.defaultBaseURL)
        #expect(LLMManProviderDescriptor.spec.endpoint?.url(environment: [:]) == LLMManSettingsReader.defaultBaseURL)
        #expect(LLMManProviderDescriptor.spec.endpoint?.url(environment: ["LLMMAN_HOST": "localhost"])?
            .absoluteString == "http://localhost:17434")
    }

    @Test
    func `keyless daemon fetch and optional activity budget remain explicit`() throws {
        let context = ProviderCutoverTestSupport.context(environment: [:])
        let daemon = try #require(LLMManProviderDescriptor.spec.scriptValues(context))
        #expect(daemon.secrets.isEmpty)
        #expect(daemon.settings == ["LLMMAN_HOST": "http://127.0.0.1:17434"])
        #expect(LiteLLMProviderDescriptor.spec.scriptValues(context) == nil)
        #expect(LiteLLMProviderDescriptor.spec.fetchTimeout(environment: [:]) == ProviderPluginRuntime.defaultTimeout)
        #expect(LiteLLMProviderDescriptor.spec.fetchTimeout(environment: ["LITELLM_MODEL_USAGE_ENABLED": "true"]) == 40)
        #expect(LiteLLMProviderDescriptor.spec.fetchTimeout(environment: ["LITELLM_MODEL_USAGE_ENABLED": "false"]) ==
            ProviderPluginRuntime.defaultTimeout)
        let values = try #require(LiteLLMProviderDescriptor.spec.scriptValues(ProviderCutoverTestSupport.context(
            environment: ["LITELLM_API_KEY": "fixture-key", "LITELLM_BASE_URL": "https://fixture.example.com"])))
        #expect(values.settings["LITELLM_MODEL_USAGE_ENABLED"] == "false")
    }
}

extension PluginProviderSpecTests {
    @Test
    func `native credential adapters and retained runtimes survive descriptor construction`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture-file-token\n".utf8).write(to: root.appendingPathComponent("token"))
        let environment = ["HF_HOME": root.path]
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "PluginSpec-native-adapter")
        let implementation = try #require(ProviderCatalog.implementation(for: .huggingface))
        #expect(implementation.isAvailable(context: .init(
            provider: .huggingface, settings: fixture.settings, environment: environment)))
        let descriptor = HuggingFaceProviderDescriptor.descriptor
        #expect(descriptor.credentials?.resolveToken(environment: environment)?.token == "fixture-file-token")
        let context = ProviderCutoverTestSupport.context(environment: environment)
        let first = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(context).first
            as? HuggingFaceScriptFetchStrategy)
        let second = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(context).first
            as? HuggingFaceScriptFetchStrategy)
        #expect(first === second)
        #expect(await first.isAvailable(context))
        let nous = await NousProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(nous.first is NousAPIFetchStrategy)
    }
}
