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

    func apiKeyDebugContext(
        provider: UsageProvider,
        processEnvironment: [String: String]) -> APIKeyDebugContext?
    {
        guard let adapter = ProviderDescriptorRegistry.descriptor(for: provider).credentials,
              let label = adapter.apiKeyDebugLabel
        else { return nil }
        let config = self.settings.providerConfig(for: provider)
        let environment = adapter.applyConfig(base: processEnvironment, config: config)
        return APIKeyDebugContext(
            label: label,
            resolution: adapter.resolveToken(environment: environment),
            configToken: config?.sanitizedAPIKey,
            hasEnvToken: adapter.resolveToken(environment: processEnvironment) != nil,
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
