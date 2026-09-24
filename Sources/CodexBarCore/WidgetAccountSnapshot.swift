import Foundation

extension WidgetSnapshot {
    /// Stable source-issued identity, separate from the provider's currently selected account.
    /// An unavailable account remains selectable without borrowing a sibling's usage.
    public struct AccountEntry: Codable, Identifiable, Sendable {
        public let id: String
        public let provider: ProviderInstanceID
        public let label: String
        public let usage: ProviderEntry?
        public let isActive: Bool

        public init(
            id: String,
            provider: ProviderInstanceID,
            label: String,
            usage: ProviderEntry?,
            isActive: Bool = false)
        {
            self.id = id
            self.provider = provider
            self.label = label
            self.usage = usage
            self.isActive = isActive
        }

        private enum CodingKeys: String, CodingKey {
            case id, provider, label, usage, isActive
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.provider = try container.decode(ProviderInstanceID.self, forKey: .provider)
            self.label = try container.decode(String.self, forKey: .label)
            self.usage = try container.decodeIfPresent(ProviderEntry.self, forKey: .usage)
            self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        }
    }

    /// Duplicate IDs are ambiguous even across providers; do not restore a saved pin or label from one.
    public func account(id: String, provider: ProviderInstanceID? = nil) -> AccountEntry? {
        let matches = self.accounts.filter { $0.id == id }
        guard matches.count == 1, let account = matches.first,
              self.enabledProviders.contains(account.provider),
              provider == nil || account.provider == provider
        else { return nil }
        return account
    }

    /// Keep the existing widget renderers and their provider-only configuration unchanged.
    /// Explicit selections fail closed on removal, disabled providers, or a mismatched provider.
    public func selectingAccount(_ accountID: String, for provider: UsageProvider) -> WidgetSnapshot {
        let account = self.account(id: accountID, provider: provider.instanceID)
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
