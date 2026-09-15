import Foundation

extension WidgetSnapshot {
    /// Stable source-issued identity, separate from the provider's currently selected account.
    /// An unavailable account remains selectable without borrowing a sibling's usage.
    public struct AccountEntry: Codable, Identifiable, Sendable {
        public let id: String
        public let provider: ProviderInstanceID
        public let label: String
        public let usage: ProviderEntry?

        public init(id: String, provider: ProviderInstanceID, label: String, usage: ProviderEntry?) {
            self.id = id
            self.provider = provider
            self.label = label
            self.usage = usage
        }
    }

    /// Keep the existing widget renderers and their provider-only configuration unchanged.
    /// Explicit selections fail closed on removal, disabled providers, or a mismatched provider.
    public func selectingAccount(_ accountID: String?, for provider: UsageProvider) -> WidgetSnapshot {
        guard let accountID else { return self }
        let account = self.accounts.first {
            $0.id == accountID && $0.provider == provider.instanceID
                && self.enabledProviders.contains(provider.instanceID)
        }
        var entries = self.entries.filter { $0.provider != provider.instanceID }
        if let usage = account?.usage, usage.provider == provider.instanceID {
            entries.append(usage)
        }
        return WidgetSnapshot(
            entries: entries,
            accounts: self.accounts,
            enabledProviders: self.enabledProviders,
            usageBarsShowUsed: self.usageBarsShowUsed,
            generatedAt: self.generatedAt)
    }
}
