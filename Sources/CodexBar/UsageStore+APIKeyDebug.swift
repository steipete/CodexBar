import CodexBarCore
import Foundation

extension UsageStore {
    struct APIKeyDebugContext {
        let label: String
        let resolution: ProviderTokenResolution?
        let configToken: String?
        let hasEnvToken: Bool
        let hasTokenAccount: Bool
    }

    func openAIAPIKeyDebugContext(processEnvironment: [String: String]) -> APIKeyDebugContext {
        self.apiKeyDebugContext(
            provider: .openai,
            label: "OPENAI_API_KEY",
            processEnvironment: processEnvironment,
            resolution: ProviderTokenResolver.openAIAPIResolution,
            hasEnvToken: { OpenAIAPISettingsReader.apiKey(environment: $0) != nil })
    }

    func azureOpenAIAPIKeyDebugContext(processEnvironment: [String: String]) -> APIKeyDebugContext {
        let config = self.settings.providerConfig(for: .azureopenai)
        let environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: processEnvironment,
            provider: .azureopenai,
            config: config)
        return APIKeyDebugContext(
            label: "AZURE_OPENAI_API_KEY",
            resolution: ProviderTokenResolver.azureOpenAIResolution(environment: environment),
            configToken: config?.sanitizedAPIKey,
            hasEnvToken: AzureOpenAISettingsReader.apiKey(environment: processEnvironment) != nil,
            hasTokenAccount: false)
    }

    func openRouterAPIKeyDebugContext(processEnvironment: [String: String]) -> APIKeyDebugContext {
        self.apiKeyDebugContext(
            provider: .openrouter,
            label: "OPENROUTER_API_KEY",
            processEnvironment: processEnvironment,
            resolution: ProviderTokenResolver.openRouterResolution,
            hasEnvToken: { OpenRouterSettingsReader.apiToken(environment: $0) != nil })
    }

    func elevenLabsAPIKeyDebugContext(processEnvironment: [String: String]) -> APIKeyDebugContext {
        self.apiKeyDebugContext(
            provider: .elevenlabs,
            label: "ELEVENLABS_API_KEY",
            processEnvironment: processEnvironment,
            resolution: ProviderTokenResolver.elevenLabsResolution,
            hasEnvToken: { ElevenLabsSettingsReader.apiKey(environment: $0) != nil })
    }

    func apiKeyDebugContext(
        provider: UsageProvider,
        label: String,
        processEnvironment: [String: String],
        resolution: ([String: String]) -> ProviderTokenResolution?,
        hasEnvToken: ([String: String]) -> Bool) -> APIKeyDebugContext
    {
        let config = self.settings.providerConfig(for: provider)
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: processEnvironment,
            provider: provider,
            config: config)
        return APIKeyDebugContext(
            label: label,
            resolution: resolution(environment),
            configToken: config?.sanitizedAPIKey,
            hasEnvToken: hasEnvToken(processEnvironment),
            hasTokenAccount: false)
    }

    nonisolated static func apiKeyDebugLine(_ context: APIKeyDebugContext) -> String {
        self.apiKeyDebugLine(
            label: context.label,
            resolution: context.resolution,
            configToken: context.configToken,
            hasEnvToken: context.hasEnvToken,
            hasTokenAccount: context.hasTokenAccount)
    }

    nonisolated static func apiKeyDebugLine(
        label: String,
        resolution: ProviderTokenResolution?,
        configToken: String?,
        hasEnvToken: Bool,
        hasTokenAccount: Bool = false) -> String
    {
        let hasAny = resolution != nil
        let hasConfigToken = !(configToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let source: String = if resolution == nil {
            "none"
        } else if hasTokenAccount, hasEnvToken {
            "settings-token-account (overrides env)"
        } else if hasTokenAccount {
            "settings-token-account"
        } else if hasConfigToken, hasEnvToken {
            "settings-config (overrides env)"
        } else if hasConfigToken {
            "settings-config"
        } else {
            resolution?.source.rawValue ?? "environment"
        }
        return "\(label)=\(hasAny ? "present" : "missing") source=\(source)"
    }
}
