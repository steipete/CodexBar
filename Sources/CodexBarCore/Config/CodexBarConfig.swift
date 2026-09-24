import Foundation

public struct CodexBarConfig: Codable, Sendable {
    public static let currentVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version
        case providers
        case hooks
    }

    private enum ProviderCodingKeys: String, CodingKey {
        case id
        case enabled
    }

    private static let rawProvidersKey = CodingUserInfoKey(rawValue: "CodexBarConfig.rawProviders")!
    private var unknownProviders: [(index: Int, id: String, enabled: Bool, data: Data)] = []
    public var unavailableProviders: [(index: Int, id: String, enabled: Bool)] {
        self.unknownProviders.map { ($0.index, $0.id, $0.enabled) }
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
            let index = providersContainer.currentIndex
            let providerDecoder = try providersContainer.superDecoder()
            let providerContainer = try providerDecoder.container(keyedBy: ProviderCodingKeys.self)
            let rawID = try providerContainer.decode(String.self, forKey: .id)
            let instanceID = ProviderInstanceID(rawValue: rawID)
            if instanceID?.firstPartyProvider != nil {
                try providers.append(ProviderConfig(from: providerDecoder))
                continue
            }
            let data: Data
            if let records = decoder.userInfo[Self.rawProvidersKey] as? [Data] {
                data = records[index]
            } else {
                let value = try ProviderConfigExtensionValue(from: providerDecoder)
                data = try JSONEncoder().encode(value.requiringExactNumbers())
            }
            if let instanceID, UserProviderPluginRegistry.plugin(for: instanceID) != nil,
               let config = Self.exactProviderConfig(from: data)
            {
                providers.append(config)
            } else {
                self.unknownProviders.append((
                    index, rawID, (try? providerContainer.decode(Bool.self, forKey: .enabled)) ?? false, data))
            }
        }
        self.providers = providers
        self.hooks = try container.decodeIfPresent(HooksConfig.self, forKey: .hooks)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.version, forKey: .version)
        try container.encodeIfPresent(self.hooks, forKey: .hooks)
        var entries = container.nestedUnkeyedContainer(forKey: .providers)
        var providers = self.providers.makeIterator()
        for unknown in self.unknownProviders {
            while entries.count < unknown.index, let provider = providers.next() {
                try entries.encode(provider)
            }
            let value = try JSONDecoder().decode(ProviderConfigExtensionValue.self, from: unknown.data)
            try entries.encode(value.requiringExactNumbers())
        }
        while let provider = providers.next() {
            try entries.encode(provider)
        }
    }

    /// File I/O keeps opaque records as JSON bytes, including numbers outside Codable's numeric range.
    public static func decode(from data: Data) throws -> Self {
        let decoder = JSONDecoder()
        let records = try OpaqueConfigJSON.providers(in: data).entries
        decoder.userInfo[Self.rawProvidersKey] = records.map { data.subdata(in: $0) }
        return try decoder.decode(Self.self, from: data)
    }

    public func encodedData(pretty: Bool = true) throws -> Data {
        var known = self
        known.unknownProviders = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try encoder.encode(known)
        guard !self.unknownProviders.isEmpty else { return data }
        let array = try OpaqueConfigJSON.providers(in: data)
        var records = array.entries.map { data.subdata(in: $0) }
        for unknown in self.unknownProviders {
            records.insert(unknown.data, at: min(unknown.index, records.count))
        }
        var result = data.subdata(in: 0..<array.range.lowerBound)
        result.append(Data("[".utf8))
        for (index, record) in records.enumerated() {
            if index > 0 { result.append(Data(",".utf8)) }
            result.append(record)
        }
        result.append(Data("]".utf8))
        result.append(data.subdata(in: array.range.upperBound..<data.count))
        return result
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
            if lhsEnabled != rhsEnabled {
                return lhsEnabled
            }
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
        var seen: Set<ProviderInstanceID> = []
        var normalized: [ProviderConfig] = []
        normalized.reserveCapacity(max(self.providers.count, UsageProvider.allCases.count))

        for var provider in self.providers {
            guard !seen.contains(provider.id) else { continue }
            seen.insert(provider.id)
            if let firstPartyProvider = provider.id.firstPartyProvider {
                ProviderDescriptorRegistry.descriptor(for: firstPartyProvider).normalizeConfig(&provider)
            }
            normalized.append(provider)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider.instanceID) {
            normalized.append(Self.defaultProviderConfig(
                provider,
                metadata: metadata,
                alibabaTokenPlanRegion: .chinaMainland))
        }

        var copy = self
        copy.version = Self.currentVersion
        copy.providers = normalized
        return copy
    }

    public func sanitizedForDump(showSecrets: Bool = false) -> CodexBarConfig {
        guard !showSecrets else { return self }
        var copy = self
        copy.providers = copy.providers.map { $0.sanitizedForDump() }
        // Unknown schemas may put credentials anywhere; only expose listing metadata by default.
        for index in copy.unknownProviders.indices {
            let unknown = copy.unknownProviders[index]
            let fields = try? JSONDecoder().decode(OpaqueProviderFields.self, from: unknown.data)
            var redacted = Dictionary(uniqueKeysWithValues: (fields?.keys ?? []).map {
                ($0, ProviderConfigExtensionValue.string("[REDACTED]"))
            })
            redacted["id"] = .string(unknown.id)
            redacted["enabled"] = .bool(unknown.enabled)
            copy.unknownProviders[index].data = (try? JSONEncoder().encode(redacted)) ?? Data("null".utf8)
        }
        return copy
    }

    public func orderedProviders() -> [ProviderInstanceID] {
        self.providers.map(\.id)
    }

    public func enabledProviders(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> [ProviderInstanceID]
    {
        self.providers.compactMap { config in
            let enabled = config.enabled ?? config.id.firstPartyProvider
                .flatMap { metadata[$0]?.defaultEnabled } ?? false
            return enabled ? config.id : nil
        }
    }

    public func providerConfig(for id: ProviderInstanceID) -> ProviderConfig? {
        if let config = self.providers.first(where: { $0.id == id }) { return config }
        // Discovery can recover while the app still holds a config loaded before the plugin was available.
        guard UserProviderPluginRegistry.plugin(for: id) != nil,
              let unknown = self.unknownProviders.first(where: { $0.id == id.rawValue })
        else { return nil }
        return try? JSONDecoder().decode(ProviderConfig.self, from: unknown.data)
    }

    public mutating func setProviderConfig(_ config: ProviderConfig) {
        if let index = self.providers.firstIndex(where: { $0.id == config.id }) {
            self.providers[index] = config
        } else if let index = self.unknownProviders.firstIndex(where: { $0.id == config.id.rawValue }) {
            guard Self.exactProviderConfig(from: self.unknownProviders[index].data) != nil else { return }
            let position = min(self.unknownProviders[index].index - index, self.providers.count)
            self.unknownProviders.remove(at: index)
            self.providers.insert(config, at: position)
        } else {
            self.providers.append(config)
        }
    }

    private static func exactProviderConfig(from data: Data) -> ProviderConfig? {
        guard OpaqueConfigJSON.hasExactIntegerTokens(in: data),
              let original = try? JSONDecoder().decode(ProviderConfig.self, from: data),
              let raw = try? JSONDecoder().decode(ProviderConfigExtensionValue.self, from: data),
              let encoded = try? JSONEncoder().encode(original),
              let roundTrip = try? JSONDecoder().decode(ProviderConfigExtensionValue.self, from: encoded),
              raw == roundTrip
        else { return nil }
        return original
    }

    public mutating func removeProviderConfig(for id: ProviderInstanceID) {
        var ids = self.providers.map(\.id.rawValue)
        var positions: [Int] = []
        for unknown in self.unknownProviders {
            let position = min(unknown.index, ids.count)
            positions.append(position)
            ids.insert(unknown.id, at: position)
        }
        for index in self.unknownProviders.indices {
            let position = positions[index]
            self.unknownProviders[index].index = position - ids.prefix(position).filter { $0 == id.rawValue }.count
        }
        self.providers.removeAll { $0.id == id }
        self.unknownProviders.removeAll { $0.id == id.rawValue }
    }

    private static func defaultProviderConfig(
        _ provider: UsageProvider,
        metadata: [UsageProvider: ProviderMetadata],
        alibabaTokenPlanRegion: AlibabaTokenPlanAPIRegion) -> ProviderConfig
    {
        ProviderConfig(
            id: provider.instanceID,
            enabled: metadata[provider]?.defaultEnabled,
            region: provider == .alibabatokenplan ? alibabaTokenPlanRegion.rawValue : nil)
    }
}

private struct OpaqueProviderFields: Decodable {
    let keys: [String]

    init(from decoder: any Decoder) throws {
        self.keys = try decoder.container(keyedBy: ProviderConfigCodingKey.self).allKeys.map(\.stringValue)
    }
}

public struct ProviderConfig: Codable, Sendable, Identifiable {
    public let id: ProviderInstanceID
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
    public var quotaWarnings: QuotaWarningConfig?
    /// User override for the provider brand color, as `#RRGGBB`. Nil keeps the descriptor default.
    public var accentColor: String?
    /// Stable menu-card item IDs hidden for this provider. Nil keeps the default of showing every item.
    public var hiddenUsageItemIDs: [String]?
    /// Arbitrary user-plugin values stay scoped to the provider instance. Secure values are redacted from config dumps.
    public var pluginSettings: [String: String]?
    public var pluginSecrets: [String: String]?
    var extensionValues: [String: ProviderConfigExtensionValue]

    public init(
        id: ProviderInstanceID,
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
        quotaWarnings: QuotaWarningConfig? = nil,
        accentColor: String? = nil,
        hiddenUsageItemIDs: [String]? = nil,
        pluginSettings: [String: String]? = nil,
        pluginSecrets: [String: String]? = nil)
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
        self.quotaWarnings = quotaWarnings
        self.accentColor = accentColor
        self.hiddenUsageItemIDs = hiddenUsageItemIDs
        self.pluginSettings = pluginSettings
        self.pluginSecrets = pluginSecrets
        self.extensionValues = [:]
    }

    public var sanitizedAPIKey: String? {
        SettingsValue.cleaned(self.apiKey)
    }

    public var sanitizedSecretKey: String? {
        SettingsValue.cleaned(self.secretKey)
    }

    public var sanitizedCookieHeader: String? {
        SettingsValue.cleaned(self.cookieHeader)
    }

    public var sanitizedRegion: String? {
        SettingsValue.cleaned(self.region)
    }

    public var sanitizedWorkspaceID: String? {
        SettingsValue.cleaned(self.workspaceID)
    }

    public var sanitizedEnterpriseHost: String? {
        SettingsValue.cleaned(self.enterpriseHost)
    }

    public func sanitizedForDump() -> ProviderConfig {
        var copy = self
        if copy.apiKey != nil {
            copy.apiKey = "[REDACTED]"
        }
        if copy.secretKey != nil {
            copy.secretKey = "[REDACTED]"
        }
        if copy.cookieHeader != nil {
            copy.cookieHeader = "[REDACTED]"
        }
        if copy.pluginSecrets != nil {
            copy.pluginSecrets = copy.pluginSecrets?.mapValues { _ in "[REDACTED]" }
        }
        if let tokenAccounts = copy.tokenAccounts {
            copy.tokenAccounts = tokenAccounts.sanitizedForDump()
        }
        return copy
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
