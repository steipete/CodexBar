import Foundation

public struct CodexBarConfig: Codable, Sendable {
    public static let currentVersion = 1

    private static let log = CodexBarLog.logger(LogCategories.configStore)

    private enum CodingKeys: String, CodingKey {
        case version
        case providers
    }

    private enum ProviderCodingKeys: String, CodingKey {
        case id
    }

    public var version: Int
    public var providers: [ProviderConfig]
    /// Optional external event hooks. Absent (nil) or disabled means no hooks run.
    public var hooks: HooksConfig?

    public init(
        version: Int = Self.currentVersion,
        providers: [ProviderConfig],
        hooks: HooksConfig? = nil)
    {
        self.version = version
        self.providers = providers
        self.hooks = hooks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)

        var providersContainer = try container.nestedUnkeyedContainer(forKey: .providers)
        var providers: [ProviderConfig] = []
        while !providersContainer.isAtEnd {
            let providerDecoder = try providersContainer.superDecoder()
            let providerContainer = try providerDecoder.container(keyedBy: ProviderCodingKeys.self)
            let rawID = try providerContainer.decode(String.self, forKey: .id)
            guard UsageProvider(rawValue: rawID) != nil else {
                Self.log.warning("Ignoring unknown provider in config", metadata: ["provider": rawID])
                continue
            }
            try providers.append(ProviderConfig(from: providerDecoder))
        }
        self.providers = providers
    }

    public static func makeDefault(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> CodexBarConfig
    {
        let providers = UsageProvider.allCases.map { provider in
            Self.defaultProviderConfig(
                provider,
                metadata: metadata,
                alibabaTokenPlanRegion: .international)
        }
        return CodexBarConfig(version: Self.currentVersion, providers: providers)
    }

    /// Alphabetical provider ordering with enabled providers on top: enabled first, then disabled,
    /// each group sorted case-insensitively by display name. Used by the Providers settings pane's
    /// alphabetical sort toggle; it never mutates the user's stored manual order.
    public static func alphabeticalProviderOrder(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata,
        enablement: (UsageProvider) -> Bool) -> [UsageProvider]
    {
        UsageProvider.allCases.sorted { lhs, rhs in
            let lhsEnabled = enablement(lhs)
            let rhsEnabled = enablement(rhs)
            if lhsEnabled != rhsEnabled { return lhsEnabled }
            let lhsName = metadata[lhs]?.displayName ?? lhs.rawValue
            let rhsName = metadata[rhs]?.displayName ?? rhs.rawValue
            switch lhsName.localizedCaseInsensitiveCompare(rhsName) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.rawValue < rhs.rawValue
            }
        }
    }

    public func normalized(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> CodexBarConfig
    {
        var seen: Set<UsageProvider> = []
        var normalized: [ProviderConfig] = []
        normalized.reserveCapacity(max(self.providers.count, UsageProvider.allCases.count))

        for var provider in self.providers {
            guard !seen.contains(provider.id) else { continue }
            seen.insert(provider.id)
            if provider.id == .deepseek {
                provider.deepseekProfileID = provider.sanitizedDeepSeekProfileID
                provider.deepseekProfileScope = provider.sanitizedDeepSeekProfileScope
            }
            normalized.append(provider)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider) {
            normalized.append(Self.defaultProviderConfig(
                provider,
                metadata: metadata,
                alibabaTokenPlanRegion: .chinaMainland))
        }

        return CodexBarConfig(
            version: Self.currentVersion,
            providers: normalized,
            hooks: self.hooks)
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

    private static func defaultProviderConfig(
        _ provider: UsageProvider,
        metadata: [UsageProvider: ProviderMetadata],
        alibabaTokenPlanRegion: AlibabaTokenPlanAPIRegion) -> ProviderConfig
    {
        ProviderConfig(
            id: provider,
            enabled: metadata[provider]?.defaultEnabled,
            region: provider == .alibabatokenplan ? alibabaTokenPlanRegion.rawValue : nil)
    }
}

public struct ProviderConfig: Codable, Sendable, Identifiable {
    public let id: UsageProvider
    public var enabled: Bool?
    public var source: ProviderSourceMode?
    public var extrasEnabled: Bool?
    public var apiKey: String?
    public var secretKey: String?
    public var cookieHeader: String?
    public var cookieSource: ProviderCookieSource?
    public var region: String?
    public var workspaceID: String?
    public var enterpriseHost: String?
    public var tokenAccounts: ProviderTokenAccountData?
    public var claudeSwapEnabled: Bool?
    public var claudeSwapShowSingleAccount: Bool?
    public var claudeSwapExecutablePath: String?
    public var codexActiveSource: CodexActiveSource?
    public var codexProfileHomePaths: [String]?
    public var antigravityPrioritizeExhaustedQuotas: Bool?
    public var quotaWarnings: QuotaWarningConfig?
    public var kiloKnownOrganizations: [KiloOrganization]?
    public var kiloEnabledOrganizationIDs: [String]?
    public var awsProfile: String?
    public var awsAuthMode: String?
    public var deepseekProfileID: String?
    public var deepseekProfileScope: String?

    public init(
        id: UsageProvider,
        enabled: Bool? = nil,
        source: ProviderSourceMode? = nil,
        extrasEnabled: Bool? = nil,
        apiKey: String? = nil,
        secretKey: String? = nil,
        cookieHeader: String? = nil,
        cookieSource: ProviderCookieSource? = nil,
        region: String? = nil,
        workspaceID: String? = nil,
        enterpriseHost: String? = nil,
        tokenAccounts: ProviderTokenAccountData? = nil,
        claudeSwapEnabled: Bool? = nil,
        claudeSwapShowSingleAccount: Bool? = nil,
        claudeSwapExecutablePath: String? = nil,
        codexActiveSource: CodexActiveSource? = nil,
        codexProfileHomePaths: [String]? = nil,
        antigravityPrioritizeExhaustedQuotas: Bool? = nil,
        quotaWarnings: QuotaWarningConfig? = nil,
        kiloKnownOrganizations: [KiloOrganization]? = nil,
        kiloEnabledOrganizationIDs: [String]? = nil,
        awsProfile: String? = nil,
        awsAuthMode: String? = nil,
        deepseekProfileID: String? = nil,
        deepseekProfileScope: String? = nil)
    {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.extrasEnabled = extrasEnabled
        self.apiKey = apiKey
        self.secretKey = secretKey
        self.cookieHeader = cookieHeader
        self.cookieSource = cookieSource
        self.region = region
        self.workspaceID = workspaceID
        self.enterpriseHost = enterpriseHost
        self.tokenAccounts = tokenAccounts
        self.claudeSwapEnabled = claudeSwapEnabled
        self.claudeSwapShowSingleAccount = claudeSwapShowSingleAccount
        self.claudeSwapExecutablePath = claudeSwapExecutablePath
        self.codexActiveSource = codexActiveSource
        self.codexProfileHomePaths = codexProfileHomePaths
        self.antigravityPrioritizeExhaustedQuotas = antigravityPrioritizeExhaustedQuotas
        self.quotaWarnings = quotaWarnings
        self.kiloKnownOrganizations = kiloKnownOrganizations
        self.kiloEnabledOrganizationIDs = kiloEnabledOrganizationIDs
        self.awsProfile = awsProfile
        self.awsAuthMode = awsAuthMode
        self.deepseekProfileID = deepseekProfileID
        self.deepseekProfileScope = deepseekProfileScope
    }

    public var sanitizedAPIKey: String? {
        Self.clean(self.apiKey)
    }

    public var sanitizedSecretKey: String? {
        Self.clean(self.secretKey)
    }

    public var sanitizedCookieHeader: String? {
        Self.clean(self.cookieHeader)
    }

    public var sanitizedRegion: String? {
        Self.clean(self.region)
    }

    public var sanitizedWorkspaceID: String? {
        Self.clean(self.workspaceID)
    }

    public var sanitizedEnterpriseHost: String? {
        Self.clean(self.enterpriseHost)
    }

    public var sanitizedClaudeSwapExecutablePath: String? {
        Self.clean(self.claudeSwapExecutablePath)
    }

    public var sanitizedAWSProfile: String? {
        Self.clean(self.awsProfile)
    }

    public var sanitizedAWSAuthMode: String? {
        Self.clean(self.awsAuthMode)
    }

    public var sanitizedDeepSeekProfileID: String? {
        Self.clean(self.deepseekProfileID).map(DeepSeekSettingsReader.canonicalProfileID)
    }

    public var sanitizedDeepSeekProfileScope: String? {
        Self.clean(self.deepseekProfileScope)
    }

    private static func clean(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
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
