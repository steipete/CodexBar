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
    public var extrasEnabled: Bool?
    public var apiKey: String?
    public var cookieHeader: String?
    public var cookieSource: ProviderCookieSource?
    public var region: String?
    public var workspaceID: String?
    public var enterpriseHost: String?
    public var tokenAccounts: ProviderTokenAccountData?
    public var codexActiveSource: CodexActiveSource?
    public var quotaWarnings: QuotaWarningConfig?

    public init(
        id: UsageProvider,
        enabled: Bool? = nil,
        source: ProviderSourceMode? = nil,
        extrasEnabled: Bool? = nil,
        apiKey: String? = nil,
        cookieHeader: String? = nil,
        cookieSource: ProviderCookieSource? = nil,
        region: String? = nil,
        workspaceID: String? = nil,
        enterpriseHost: String? = nil,
        tokenAccounts: ProviderTokenAccountData? = nil,
        codexActiveSource: CodexActiveSource? = nil,
        quotaWarnings: QuotaWarningConfig? = nil)
    {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.extrasEnabled = extrasEnabled
        self.apiKey = apiKey
        self.cookieHeader = cookieHeader
        self.cookieSource = cookieSource
        self.region = region
        self.workspaceID = workspaceID
        self.enterpriseHost = enterpriseHost
        self.tokenAccounts = tokenAccounts
        self.codexActiveSource = codexActiveSource
        self.quotaWarnings = quotaWarnings
    }

    public var sanitizedAPIKey: String? {
        Self.clean(self.apiKey)
    }

    public var sanitizedCookieHeader: String? {
        Self.clean(self.cookieHeader)
    }

    public var sanitizedEnterpriseHost: String? {
        Self.clean(self.enterpriseHost)
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

public enum QuotaWarningWindow: String, Codable, Sendable, CaseIterable {
    case session
    case weekly

    public var displayName: String {
        switch self {
        case .session:
            "session"
        case .weekly:
            "weekly"
        }
    }
}

public struct QuotaWarningWindowConfig: Codable, Sendable, Equatable {
    public var thresholds: [Int]?
    public var enabled: Bool?

    public init(thresholds: [Int]? = nil, enabled: Bool? = nil) {
        self.thresholds = thresholds.map(QuotaWarningThresholds.sanitized)
        self.enabled = enabled
    }

    public var hasOverride: Bool {
        self.thresholds != nil || self.enabled != nil
    }

    public func isEnabled(global: Bool) -> Bool {
        self.enabled ?? (self.thresholds != nil ? true : global)
    }
}

public struct QuotaWarningConfig: Codable, Sendable, Equatable {
    public var session: QuotaWarningWindowConfig?
    public var weekly: QuotaWarningWindowConfig?

    public init(
        session: QuotaWarningWindowConfig? = nil,
        weekly: QuotaWarningWindowConfig? = nil)
    {
        self.session = session
        self.weekly = weekly
    }

    public func thresholds(for window: QuotaWarningWindow, global: [Int]) -> [Int] {
        switch window {
        case .session:
            QuotaWarningThresholds.sanitized(self.session?.thresholds ?? global)
        case .weekly:
            QuotaWarningThresholds.sanitized(self.weekly?.thresholds ?? global)
        }
    }

    public func isEnabled(for window: QuotaWarningWindow, global: Bool) -> Bool {
        switch window {
        case .session:
            self.session?.isEnabled(global: global) ?? global
        case .weekly:
            self.weekly?.isEnabled(global: global) ?? global
        }
    }

    public func hasOverride(for window: QuotaWarningWindow) -> Bool {
        switch window {
        case .session:
            self.session?.hasOverride ?? false
        case .weekly:
            self.weekly?.hasOverride ?? false
        }
    }

    public var isEmpty: Bool {
        self.session?.hasOverride != true && self.weekly?.hasOverride != true
    }
}

public enum QuotaWarningThresholds {
    public static let defaults = [50, 20]
    public static let allowedRange = 0...99

    public static func sanitized(_ raw: [Int]) -> [Int] {
        guard !raw.isEmpty else { return self.defaults }

        let unique = Set(raw.map(self.clamped))
        let sorted = unique.sorted(by: >)
        return sorted.isEmpty ? self.defaults : sorted
    }

    public static func active(_ raw: [Int]) -> [Int] {
        self.sanitized(raw).filter { $0 > 0 }
    }

    public static func resolved(upper: Int?, lower: Int?) -> [Int] {
        guard upper != nil || lower != nil else { return self.defaults }

        let resolvedUpper = self.clamped(upper ?? self.defaults[0])
        let lowerDefault = resolvedUpper < self.defaults[1] ? 0 : self.defaults[1]
        let resolvedLower = self.clamped(lower ?? lowerDefault)
        return self.sanitized([resolvedUpper, resolvedLower])
    }

    public static func clamped(_ value: Int) -> Int {
        min(max(value, self.allowedRange.lowerBound), self.allowedRange.upperBound)
    }
}
