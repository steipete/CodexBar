import CodexBarCore
import Foundation

struct TokenAccountOverride: Sendable {
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
        if let override, override.provider == provider { return override.account }
        return settings.selectedTokenAccount(for: provider)
    }
}
