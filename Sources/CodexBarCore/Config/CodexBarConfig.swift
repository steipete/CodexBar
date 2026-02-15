import Foundation

public struct CodexBarConfig: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var providers: [ProviderConfig]

    public init(version: Int = Self.currentVersion, providers: [ProviderConfig]) {
        self.version = version
        self.providers = providers
    }

    public static func makeDefault(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> CodexBarConfig
    {
        let providers = UsageProvider.allCases.map { provider in
            ProviderConfig(
                id: provider,
                enabled: metadata[provider]?.defaultEnabled)
        }
        return CodexBarConfig(version: Self.currentVersion, providers: providers)
    }

    public func normalized(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> CodexBarConfig
    {
        var seen: Set<UsageProvider> = []
        var normalized: [ProviderConfig] = []
        normalized.reserveCapacity(max(self.providers.count, UsageProvider.allCases.count))

        for provider in self.providers {
            guard !seen.contains(provider.id) else { continue }
            seen.insert(provider.id)
            normalized.append(provider)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider) {
            normalized.append(ProviderConfig(
                id: provider,
                enabled: metadata[provider]?.defaultEnabled))
        }

        return CodexBarConfig(
            version: Self.currentVersion,
            providers: normalized)
    }

    public func orderedProviders() -> [UsageProvider] {
        self.providers.map(\.id)
    }

    public func enabledProviders(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> [UsageProvider]
    {
        self.providers.compactMap { config in
            let enabled = config.enabled ?? metadata[config.id]?.defaultEnabled ?? false
            return enabled ? config.id : nil
        }
    }

    public func providerConfig(for id: UsageProvider) -> ProviderConfig? {
        self.providers.first(where: { $0.id == id })
    }

    public mutating func setProviderConfig(_ config: ProviderConfig) {
        if let index = self.providers.firstIndex(where: { $0.id == config.id }) {
            self.providers[index] = config
        } else {
            self.providers.append(config)
        }
    }
}

public struct ProviderConfig: Codable, Sendable, Identifiable {
    public let id: UsageProvider
    public var enabled: Bool?
    public var source: ProviderSourceMode?
    public var apiKey: String?
    public var cookieHeader: String?
    public var cookieSource: ProviderCookieSource?
    public var region: String?
    public var workspaceID: String?
    public var tokenAccounts: ProviderTokenAccountData?
    public var usageSource: String?

    public init(
        id: UsageProvider,
        enabled: Bool? = nil,
        source: ProviderSourceMode? = nil,
        apiKey: String? = nil,
        cookieHeader: String? = nil,
        cookieSource: ProviderCookieSource? = nil,
        region: String? = nil,
        workspaceID: String? = nil,
        tokenAccounts: ProviderTokenAccountData? = nil,
        usageSource: String? = nil)
    {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.apiKey = apiKey
        self.cookieHeader = cookieHeader
        self.cookieSource = cookieSource
        self.region = region
        self.workspaceID = workspaceID
        self.tokenAccounts = tokenAccounts
        self.usageSource = usageSource
    }

    public var sanitizedAPIKey: String? {
        Self.clean(self.apiKey)
    }

    public var sanitizedCookieHeader: String? {
        Self.clean(self.cookieHeader)
    }

    private static func clean(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
