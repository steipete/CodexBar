import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct ProviderCredentialCharacterizationTests {
    private struct APIKeyProjectionFixture: Sendable {
        let provider: UsageProvider
        let environmentKey: String
    }

    private struct DiagnoseFixture: Sendable {
        let provider: UsageProvider
        let environment: [String: String]
        let mode: String
    }

    @Test
    func `config API key projection is explicit for every supported provider`() {
        let fixtures: [APIKeyProjectionFixture] = [
            .init(provider: .amp, environmentKey: "AMP_API_KEY"),
            .init(provider: .openai, environmentKey: "OPENAI_ADMIN_KEY"),
            .init(provider: .azureopenai, environmentKey: "AZURE_OPENAI_API_KEY"),
            .init(provider: .claude, environmentKey: "ANTHROPIC_ADMIN_KEY"),
            .init(provider: .clinepass, environmentKey: "CLINE_API_KEY"),
            .init(provider: .zai, environmentKey: "Z_AI_API_KEY"),
            .init(provider: .minimax, environmentKey: "MINIMAX_API_KEY"),
            .init(provider: .alibaba, environmentKey: "ALIBABA_CODING_PLAN_API_KEY"),
            .init(provider: .kilo, environmentKey: "KILO_API_KEY"),
            .init(provider: .synthetic, environmentKey: "SYNTHETIC_API_KEY"),
            .init(provider: .openrouter, environmentKey: "OPENROUTER_API_KEY"),
            .init(provider: .elevenlabs, environmentKey: "ELEVENLABS_API_KEY"),
            .init(provider: .kimi, environmentKey: "KIMI_CODE_API_KEY"),
            .init(provider: .ollama, environmentKey: "OLLAMA_API_KEY"),
            .init(provider: .venice, environmentKey: "VENICE_API_KEY"),
            .init(provider: .deepgram, environmentKey: "DEEPGRAM_API_KEY"),
            .init(provider: .groq, environmentKey: "GROQ_API_KEY"),
            .init(provider: .llmproxy, environmentKey: "LLM_PROXY_API_KEY"),
            .init(provider: .chutes, environmentKey: "CHUTES_API_KEY"),
            .init(provider: .poe, environmentKey: "POE_API_KEY"),
            .init(provider: .litellm, environmentKey: "LITELLM_API_KEY"),
            .init(provider: .clawrouter, environmentKey: "CLAWROUTER_API_KEY"),
            .init(provider: .factory, environmentKey: "FACTORY_API_KEY"),
            .init(provider: .sub2api, environmentKey: "SUB2API_API_KEY"),
            .init(provider: .neuralwatt, environmentKey: "NEURALWATT_API_KEY"),
            .init(provider: .zenmux, environmentKey: "ZENMUX_MANAGEMENT_API_KEY"),
            .init(provider: .deepinfra, environmentKey: "DEEPINFRA_API_KEY"),
            .init(provider: .aiand, environmentKey: "AIAND_API_KEY"),
            .init(provider: .xai, environmentKey: "XAI_MANAGEMENT_API_KEY"),
            .init(provider: .copilot, environmentKey: "COPILOT_API_TOKEN"),
            .init(provider: .warp, environmentKey: "WARP_API_KEY"),
            .init(provider: .codebuff, environmentKey: "CODEBUFF_API_KEY"),
            .init(provider: .crof, environmentKey: "CROF_API_KEY"),
            .init(provider: .doubao, environmentKey: "ARK_API_KEY"),
        ]

        for fixture in fixtures {
            let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
                base: ["BASE": "preserved"],
                provider: fixture.provider,
                config: ProviderConfig(id: fixture.provider.instanceID, apiKey: "config-token"))
            #expect(environment["BASE"] == "preserved", Comment(rawValue: fixture.provider.rawValue))
            #expect(environment[fixture.environmentKey] == "config-token", Comment(rawValue: fixture.provider.rawValue))
            #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: fixture.provider))
        }

        for fixture in fixtures where fixture.provider != .codebuff && fixture.provider != .crof {
            let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
                base: [fixture.environmentKey: "environment-token"],
                provider: fixture.provider,
                config: ProviderConfig(id: fixture.provider.instanceID, apiKey: "config-token"))
            #expect(environment[fixture.environmentKey] == "config-token", Comment(rawValue: fixture.provider.rawValue))
        }
        for fixture in fixtures where fixture.provider == .codebuff || fixture.provider == .crof {
            let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
                base: [fixture.environmentKey: "environment-token"],
                provider: fixture.provider,
                config: ProviderConfig(id: fixture.provider.instanceID, apiKey: "config-token"))
            #expect(
                environment[fixture.environmentKey] == "environment-token",
                Comment(rawValue: fixture.provider.rawValue))
        }

        var moonshot = ProviderConfig(id: .moonshot, apiKey: "config-token")
        moonshot.apiKeyRegion = MoonshotRegion.international.rawValue
        let moonshotEnvironment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:], provider: .moonshot, config: moonshot)
        #expect(moonshotEnvironment == [
            "CODEXBAR_MOONSHOT_API_KEY": "config-token",
            "CODEXBAR_MOONSHOT_API_KEY_REGION": "international",
        ])
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .moonshot))
    }

    @Test
    func `multi field config projections preserve exact outputs`() {
        let openAI = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .openai,
            config: ProviderConfig(id: .openai, apiKey: "key", workspaceID: "project"))
        #expect(openAI == ["OPENAI_ADMIN_KEY": "key", "OPENAI_PROJECT_ID": "project"])

        let azure = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .azureopenai,
            config: ProviderConfig(
                id: .azureopenai,
                apiKey: "key",
                workspaceID: "deployment",
                enterpriseHost: "https://azure.example"))
        #expect(azure == [
            "AZURE_OPENAI_API_KEY": "key",
            "AZURE_OPENAI_DEPLOYMENT_NAME": "deployment",
            "AZURE_OPENAI_ENDPOINT": "https://azure.example",
        ])

        let deepgram = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .deepgram,
            config: ProviderConfig(id: .deepgram, apiKey: "key", workspaceID: "project"))
        #expect(deepgram == ["DEEPGRAM_API_KEY": "key", "DEEPGRAM_PROJECT_ID": "project"])

        let xai = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .xai,
            config: ProviderConfig(id: .xai, apiKey: "key", workspaceID: "team"))
        #expect(xai == ["XAI_MANAGEMENT_API_KEY": "key", "XAI_TEAM_ID": "team"])

        let bedrock = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .bedrock,
            config: ProviderConfig(id: .bedrock, apiKey: "access", secretKey: "secret", region: "us-west-2"))
        #expect(bedrock["AWS_ACCESS_KEY_ID"] == "access")
        #expect(bedrock["AWS_SECRET_ACCESS_KEY"] == "secret")
        #expect(bedrock["AWS_REGION"] == "us-west-2")

        let doubao = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: ["ARK_API_KEY": "remove-me"],
            provider: .doubao,
            config: ProviderConfig(id: .doubao, apiKey: "AKLT-access", secretKey: "secret", region: "cn-beijing"))
        #expect(doubao["ARK_API_KEY"] == "remove-me")
        #expect(doubao["VOLCENGINE_ACCESS_KEY_ID"] == "AKLT-access")
        #expect(doubao["VOLCENGINE_SECRET_ACCESS_KEY"] == "secret")
        #expect(doubao["VOLCENGINE_REGION"] == "cn-beijing")

        let endpointFixtures: [(UsageProvider, String, String)] = [
            (.llmproxy, "LLM_PROXY_API_KEY", "LLM_PROXY_BASE_URL"),
            (.litellm, "LITELLM_API_KEY", "LITELLM_BASE_URL"),
            (.clawrouter, "CLAWROUTER_API_KEY", "CLAWROUTER_BASE_URL"),
            (.sub2api, "SUB2API_API_KEY", "SUB2API_BASE_URL"),
        ]
        for (provider, keyName, endpointName) in endpointFixtures {
            let environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
                base: [:],
                provider: provider,
                config: ProviderConfig(id: provider.instanceID, apiKey: "key", enterpriseHost: "https://api.example"))
            #expect(environment == [keyName: "key", endpointName: "https://api.example"])
        }

        let wayfinder = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .wayfinder,
            config: ProviderConfig(id: .wayfinder, apiKey: "ignored", enterpriseHost: "https://api.example"))
        #expect(wayfinder == ["WAYFINDER_GATEWAY_URL": "https://api.example"])

        var deepSeekConfig = ProviderConfig(id: .deepseek, cookieHeader: "platform-token")
        deepSeekConfig.deepseekProfileID = "profile"
        deepSeekConfig.deepseekProfileScope = "team"
        let deepSeek = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:], provider: .deepseek, config: deepSeekConfig)
        #expect(deepSeek == [
            "CODEXBAR_DEEPSEEK_PROFILE_ID": "profile",
            "CODEXBAR_DEEPSEEK_PROFILE_SCOPE": "team",
            "DEEPSEEK_PLATFORM_TOKEN": "platform-token",
        ])

        let sakana = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .sakana,
            config: ProviderConfig(id: .sakana, cookieHeader: "session=cookie"))
        #expect(sakana == ["SAKANA_COOKIE": "session=cookie"])

        let longCat = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .longcat,
            config: ProviderConfig(id: .longcat, cookieHeader: "session=cookie", cookieSource: .manual))
        #expect(longCat == ["LONGCAT_MANUAL_COOKIE": "session=cookie"])

        let kimi = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .kimi,
            config: ProviderConfig(id: .kimi, apiKey: "key", enterpriseHost: "https://api.example"))
        #expect(kimi == ["KIMI_CODE_API_KEY": "key", "KIMI_CODE_BASE_URL": "https://api.example"])
    }

    @Test
    func `token account catalog names every supported provider and injection mode`() {
        let environmentProviders: [(UsageProvider, String)] = [
            (.openai, "OPENAI_ADMIN_KEY"),
            (.openrouter, "OPENROUTER_API_KEY"),
            (.deepseek, "DEEPSEEK_API_KEY"),
            (.deepinfra, "DEEPINFRA_API_KEY"),
            (.antigravity, "ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"),
            (.zai, "Z_AI_API_KEY"),
            (.copilot, "COPILOT_API_TOKEN"),
            (.venice, "VENICE_API_KEY"),
            (.elevenlabs, "ELEVENLABS_API_KEY"),
            (.neuralwatt, "NEURALWATT_API_KEY"),
            (.groq, "GROQ_API_KEY"),
            (.llmproxy, "LLM_PROXY_API_KEY"),
            (.muse, "META_API_KEY"),
            (.litellm, "LITELLM_API_KEY"),
            (.sub2api, "SUB2API_API_KEY"),
            (.ibmbob, "BOBSHELL_API_KEY"),
            (.grok, "GROK_OAUTH_TOKEN"),
        ]
        let cookieProviders: [UsageProvider] = [
            .claude, .cursor, .opencode, .opencodego, .factory, .minimax, .manus,
            .augment, .ollama, .abacus, .mistral, .qoder, .stepfun,
        ]

        for (provider, key) in environmentProviders {
            let support = TokenAccountSupportCatalog.support(for: provider)
            guard case let .environment(actualKey) = support?.injection else {
                Issue.record("Expected environment injection for \(provider.rawValue)")
                continue
            }
            #expect(actualKey == key)
            #expect(TokenAccountSupportCatalog.envOverride(for: provider, token: "account-token") == [
                key: "account-token",
            ])
        }
        for provider in cookieProviders {
            let support = TokenAccountSupportCatalog.support(for: provider)
            guard case .cookieHeader = support?.injection else {
                Issue.record("Expected cookie injection for \(provider.rawValue)")
                continue
            }
            #expect(support?.requiresManualCookieSource == true)
        }

        let normalizedCookieHeaders: [UsageProvider: String] = [
            .claude: "sessionKey=account-token",
            .cursor: "account-token",
            .opencode: "account-token",
            .opencodego: "account-token",
            .factory: "account-token",
            .minimax: "account-token",
            .manus: "session_id=account-token",
            .augment: "account-token",
            .ollama: "__Secure-session=account-token",
            .abacus: "account-token",
            .mistral: "account-token",
            .qoder: "account-token",
            .stepfun: "account-token",
        ]
        for provider in cookieProviders {
            #expect(TokenAccountSupportCatalog.normalizedCookieHeader(
                for: provider,
                token: "account-token") == normalizedCookieHeaders[provider])
            let resolved = ProviderCookieSettingsResolver.resolve(
                provider: provider,
                configuredSource: .auto,
                configuredHeader: "config-cookie",
                selectedAccount: ProviderTokenAccount(
                    id: UUID(), label: "fixture", token: "account-token", addedAt: 0, lastUsed: nil))
            #expect(resolved.cookieSource == .manual)
            #expect(resolved.manualCookieHeader == normalizedCookieHeaders[provider])
        }

        let actual = Set(ProviderDescriptorRegistry.all.compactMap { descriptor in
            TokenAccountSupportCatalog.support(for: descriptor.id) == nil ? nil : descriptor.id
        })
        #expect(actual == Set(environmentProviders.map(\.0) + cookieProviders))
    }

    @Test
    func `token accounts override config and environment credentials`() {
        let fixtures: [(UsageProvider, String)] = [
            (.openai, "OPENAI_ADMIN_KEY"), (.openrouter, "OPENROUTER_API_KEY"),
            (.deepseek, "DEEPSEEK_API_KEY"), (.deepinfra, "DEEPINFRA_API_KEY"),
            (.zai, "Z_AI_API_KEY"), (.copilot, "COPILOT_API_TOKEN"),
            (.venice, "VENICE_API_KEY"), (.elevenlabs, "ELEVENLABS_API_KEY"),
            (.neuralwatt, "NEURALWATT_API_KEY"), (.groq, "GROQ_API_KEY"),
            (.llmproxy, "LLM_PROXY_API_KEY"), (.litellm, "LITELLM_API_KEY"),
            (.sub2api, "SUB2API_API_KEY"), (.antigravity, "ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"),
            (.ibmbob, "BOBSHELL_API_KEY"),
        ]
        let account = ProviderTokenAccount(
            id: UUID(), label: "fixture", token: "account-token", addedAt: 0, lastUsed: nil)
        for (provider, key) in fixtures {
            let environment = ProviderEnvironmentResolver.resolve(
                base: [key: "environment-token"],
                provider: provider,
                config: ProviderConfig(id: provider.instanceID, apiKey: "config-token"),
                selectedAccount: account)
            #expect(environment[key] == "account-token", Comment(rawValue: provider.rawValue))
        }
    }

    @Test
    func `provider validation verdicts remain stable`() {
        let regionFixtures: [(UsageProvider, String, String)] = [
            (.minimax, MiniMaxAPIRegion.global.rawValue, "invalid-minimax"),
            (.zai, ZaiAPIRegion.global.rawValue, "invalid-zai"),
            (.alibaba, AlibabaCodingPlanAPIRegion.international.rawValue, "invalid-alibaba"),
            (.alibabatokenplan, AlibabaTokenPlanAPIRegion.chinaMainland.rawValue, "invalid-token-plan"),
            (.moonshot, MoonshotRegion.international.rawValue, "invalid-moonshot"),
        ]
        for (provider, valid, invalid) in regionFixtures {
            #expect(Self.issueCodes(for: ProviderConfig(id: provider.instanceID, region: valid)).isEmpty)
            #expect(Self.issueCodes(for: ProviderConfig(id: provider.instanceID, region: invalid))
                .contains("invalid_region"))
        }
        #expect(!Self.issueCodes(for: ProviderConfig(id: .bedrock, region: "custom")).contains("region_unused"))
        #expect(!Self.issueCodes(for: ProviderConfig(id: .doubao, region: "custom")).contains("region_unused"))
        #expect(Self.issueCodes(for: ProviderConfig(
            id: .sub2api,
            enterpriseHost: "not a URL")).contains("invalid_enterprise_host"))
        #expect(!Self.issueCodes(for: ProviderConfig(
            id: .sub2api,
            enterpriseHost: "https://api.example")).contains("invalid_enterprise_host"))

        let incompleteTeam = ProviderTokenAccount(
            id: UUID(),
            label: "team",
            token: "token",
            addedAt: 0,
            lastUsed: nil,
            usageScope: ZaiUsageScope.team.rawValue)
        #expect(Self.issueCodes(for: ProviderConfig(
            id: .zai,
            tokenAccounts: ProviderTokenAccountData(
                version: 1,
                accounts: [incompleteTeam],
                activeIndex: 0))).contains("zai_team_context_missing"))
    }

    @Test
    func `CLI diagnose classifies every credential environment`() {
        let fixtures: [DiagnoseFixture] = [
            .init(provider: .alibaba, environment: ["ALIBABA_CODING_PLAN_API_KEY": "token"], mode: "api"),
            .init(provider: .azureopenai, environment: ["AZURE_OPENAI_API_KEY": "token"], mode: "api"),
            .init(
                provider: .bedrock,
                environment: ["AWS_ACCESS_KEY_ID": "id", "AWS_SECRET_ACCESS_KEY": "secret"],
                mode: "api"),
            .init(provider: .claude, environment: ["ANTHROPIC_ADMIN_KEY": "token"], mode: "api"),
            .init(provider: .clinepass, environment: ["CLINE_API_KEY": "token"], mode: "api"),
            .init(provider: .codebuff, environment: ["CODEBUFF_API_KEY": "token"], mode: "api"),
            .init(provider: .chutes, environment: ["CHUTES_API_KEY": "token"], mode: "api"),
            .init(provider: .zenmux, environment: ["ZENMUX_MANAGEMENT_API_KEY": "token"], mode: "api"),
            .init(provider: .aiand, environment: ["AIAND_API_KEY": "token"], mode: "api"),
            .init(provider: .crof, environment: ["CROF_API_KEY": "token"], mode: "api"),
            .init(provider: .deepgram, environment: ["DEEPGRAM_API_KEY": "token"], mode: "api"),
            .init(provider: .deepseek, environment: ["DEEPSEEK_API_KEY": "token"], mode: "api"),
            .init(provider: .deepinfra, environment: ["DEEPINFRA_API_KEY": "token"], mode: "api"),
            .init(provider: .doubao, environment: ["ARK_API_KEY": "token"], mode: "api"),
            .init(provider: .elevenlabs, environment: ["ELEVENLABS_API_KEY": "token"], mode: "api"),
            .init(provider: .groq, environment: ["GROQ_API_KEY": "token"], mode: "api"),
            .init(provider: .kilo, environment: ["KILO_API_KEY": "token"], mode: "api"),
            .init(provider: .factory, environment: ["FACTORY_API_KEY": "token"], mode: "api"),
            .init(provider: .neuralwatt, environment: ["NEURALWATT_API_KEY": "token"], mode: "api"),
            .init(provider: .kimi, environment: ["KIMI_CODE_API_KEY": "token"], mode: "api"),
            .init(provider: .llmproxy, environment: ["LLM_PROXY_API_KEY": "token"], mode: "api"),
            .init(provider: .clawrouter, environment: ["CLAWROUTER_API_KEY": "token"], mode: "api"),
            .init(provider: .sub2api, environment: ["SUB2API_API_KEY": "token"], mode: "api"),
            .init(provider: .moonshot, environment: ["MOONSHOT_API_KEY": "token"], mode: "api"),
            .init(provider: .ollama, environment: ["OLLAMA_API_KEY": "token"], mode: "api"),
            .init(provider: .openai, environment: ["OPENAI_ADMIN_KEY": "token"], mode: "api"),
            .init(provider: .openrouter, environment: ["OPENROUTER_API_KEY": "token"], mode: "api"),
            .init(provider: .stepfun, environment: ["STEPFUN_TOKEN": "token"], mode: "api"),
            .init(provider: .synthetic, environment: ["SYNTHETIC_API_KEY": "token"], mode: "api"),
            .init(provider: .venice, environment: ["VENICE_API_KEY": "token"], mode: "api"),
            .init(provider: .warp, environment: ["WARP_API_KEY": "token"], mode: "api"),
            .init(provider: .xai, environment: ["XAI_MANAGEMENT_API_KEY": "token"], mode: "api"),
            .init(provider: .zai, environment: ["Z_AI_API_KEY": "token"], mode: "api"),
            .init(provider: .alibabatokenplan, environment: ["ALIBABA_TOKEN_PLAN_COOKIE": "cookie"], mode: "web"),
            .init(provider: .qwencloud, environment: ["QWEN_CLOUD_COOKIE": "cookie"], mode: "web"),
            .init(provider: .kimi, environment: ["KIMI_AUTH_TOKEN": "cookie"], mode: "web"),
            .init(provider: .manus, environment: ["MANUS_SESSION_TOKEN": "cookie"], mode: "web"),
            .init(provider: .perplexity, environment: ["PERPLEXITY_SESSION_TOKEN": "cookie"], mode: "web"),
        ]

        for fixture in fixtures {
            let summary = CodexBarCLI._diagnosticAuthSummaryForTesting(
                provider: fixture.provider,
                account: nil,
                config: nil,
                environment: fixture.environment,
                settings: nil)
            #expect(summary.configured, Comment(rawValue: fixture.provider.rawValue))
            #expect(summary.modes == [fixture.mode], Comment(rawValue: fixture.provider.rawValue))
        }
    }

    private static func issueCodes(for provider: ProviderConfig) -> Set<String> {
        Set(CodexBarConfigValidator.validate(CodexBarConfig(providers: [provider])).map(\.code))
    }
}
