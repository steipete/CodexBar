import CodexBarCore
import Foundation

struct TokenAccountOverride {
    let provider: UsageProvider
    let account: ProviderTokenAccount
}

enum ProviderTokenAccountSelection {
    @MainActor
    static func selectedAccount(
        provider: UsageProvider,
        settings: SettingsStore,
        override: TokenAccountOverride?) -> ProviderTokenAccount?
    {
        if let override, override.provider == provider {
            return override.account
        }
        return settings.effectiveSelectedTokenAccount(for: provider)
    }

    @MainActor
    static func shouldIncludeOptionalUsage(
        provider: UsageProvider,
        settings: SettingsStore,
        override: TokenAccountOverride?) -> Bool
    {
        guard provider == .deepseek else { return settings.showOptionalCreditsAndExtraUsage }
        guard settings.costUsageEnabled, settings.showOptionalCreditsAndExtraUsage else { return false }
        guard let override, override.provider == provider else { return true }
        return settings.selectedTokenAccount(for: provider)?.id == override.account.id
    }
}
