import Foundation

extension ProviderConfig {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case enabled
        case source
        case extrasEnabled
        case apiKey
        case secretKey
        case cookieHeader
        case cookieSource
        case region
        case workspaceID
        case enterpriseHost
        case tokenAccounts
        case quotaWarnings
        case accentColor
        case pluginSettings
        case pluginSecrets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ProviderConfigCodingKey.self)
        self.id = try container.decode(ProviderInstanceID.self, forKey: .init(CodingKeys.id.rawValue))
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .init(CodingKeys.enabled.rawValue))
        self.source = try container.decodeIfPresent(ProviderSourceMode.self, forKey: .init(CodingKeys.source.rawValue))
        self.extrasEnabled = try container.decodeIfPresent(Bool.self, forKey: .init(CodingKeys.extrasEnabled.rawValue))
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .init(CodingKeys.apiKey.rawValue))
        self.secretKey = try container.decodeIfPresent(String.self, forKey: .init(CodingKeys.secretKey.rawValue))
        self.cookieHeader = try container.decodeIfPresent(String.self, forKey: .init(CodingKeys.cookieHeader.rawValue))
        self.cookieSource = try container.decodeIfPresent(
            ProviderCookieSource.self,
            forKey: .init(CodingKeys.cookieSource.rawValue))
        self.region = try container.decodeIfPresent(String.self, forKey: .init(CodingKeys.region.rawValue))
        self.workspaceID = try container.decodeIfPresent(String.self, forKey: .init(CodingKeys.workspaceID.rawValue))
        self.enterpriseHost = try container.decodeIfPresent(
            String.self,
            forKey: .init(CodingKeys.enterpriseHost.rawValue))
        self.tokenAccounts = try container.decodeIfPresent(
            ProviderTokenAccountData.self,
            forKey: .init(CodingKeys.tokenAccounts.rawValue))
        self.quotaWarnings = try container.decodeIfPresent(
            QuotaWarningConfig.self,
            forKey: .init(CodingKeys.quotaWarnings.rawValue))
        self.accentColor = try container.decodeIfPresent(String.self, forKey: .init(CodingKeys.accentColor.rawValue))
        self.pluginSettings = try container.decodeIfPresent(
            [String: String].self,
            forKey: .init(CodingKeys.pluginSettings.rawValue))
        self.pluginSecrets = try container.decodeIfPresent(
            [String: String].self,
            forKey: .init(CodingKeys.pluginSecrets.rawValue))

        let genericKeys = Set(CodingKeys.allCases.map(\.rawValue))
        self.extensionValues = try container.allKeys.reduce(into: [:]) { values, key in
            guard !genericKeys.contains(key.stringValue), try !container.decodeNil(forKey: key) else { return }
            values[key.stringValue] = try container.decode(ProviderConfigExtensionValue.self, forKey: key)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ProviderConfigCodingKey.self)
        try container.encode(self.id, forKey: .init(CodingKeys.id.rawValue))
        try container.encodeIfPresent(self.enabled, forKey: .init(CodingKeys.enabled.rawValue))
        try container.encodeIfPresent(self.source, forKey: .init(CodingKeys.source.rawValue))
        try container.encodeIfPresent(self.extrasEnabled, forKey: .init(CodingKeys.extrasEnabled.rawValue))
        try container.encodeIfPresent(self.apiKey, forKey: .init(CodingKeys.apiKey.rawValue))
        try container.encodeIfPresent(self.secretKey, forKey: .init(CodingKeys.secretKey.rawValue))
        try container.encodeIfPresent(self.cookieHeader, forKey: .init(CodingKeys.cookieHeader.rawValue))
        try container.encodeIfPresent(self.cookieSource, forKey: .init(CodingKeys.cookieSource.rawValue))
        try container.encodeIfPresent(self.region, forKey: .init(CodingKeys.region.rawValue))
        try container.encodeIfPresent(self.workspaceID, forKey: .init(CodingKeys.workspaceID.rawValue))
        try container.encodeIfPresent(self.enterpriseHost, forKey: .init(CodingKeys.enterpriseHost.rawValue))
        try container.encodeIfPresent(self.tokenAccounts, forKey: .init(CodingKeys.tokenAccounts.rawValue))
        try container.encodeIfPresent(self.quotaWarnings, forKey: .init(CodingKeys.quotaWarnings.rawValue))
        try container.encodeIfPresent(self.accentColor, forKey: .init(CodingKeys.accentColor.rawValue))
        try container.encodeIfPresent(self.pluginSettings, forKey: .init(CodingKeys.pluginSettings.rawValue))
        try container.encodeIfPresent(self.pluginSecrets, forKey: .init(CodingKeys.pluginSecrets.rawValue))
        for (key, value) in self.extensionValues {
            try container.encode(value, forKey: .init(key))
        }
    }

    func extensionValue<Value: Codable>(_ type: Value.Type = Value.self, forKey key: String) -> Value? {
        guard let value = self.extensionValues[key],
              let data = try? JSONEncoder().encode(value)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    mutating func setExtensionValue(_ value: (some Codable)?, forKey key: String) {
        precondition(
            !CodingKeys.allCases.map(\.rawValue).contains(key),
            "Provider extension key collides with a generic key")
        guard let value else {
            self.extensionValues[key] = nil
            return
        }
        guard let data = try? JSONEncoder().encode(value),
              let encoded = try? JSONDecoder().decode(ProviderConfigExtensionValue.self, from: data)
        else {
            assertionFailure("Provider config extension value must be JSON encodable")
            return
        }
        self.extensionValues[key] = encoded
    }
}

private struct ProviderConfigCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        nil
    }
}

enum ProviderConfigExtensionValue: Codable, Sendable {
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: Self].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
