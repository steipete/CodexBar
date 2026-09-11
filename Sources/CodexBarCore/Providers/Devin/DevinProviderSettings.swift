import Foundation

public struct DevinProviderSettings: Sendable {
    public let cookieSource: ProviderCookieSource
    public let manualBearerToken: String?
    public let organization: String?
    /// Optional enterprise deployment host (e.g. `your-team.devinenterprise.com`). When set,
    /// CodexBar uses the personal-analytics ACU cycle endpoint on that host instead of the
    /// default app.devin.ai daily/weekly quota endpoint.
    public let apiHost: String?

    public init(
        cookieSource: ProviderCookieSource,
        manualBearerToken: String?,
        organization: String?,
        apiHost: String? = nil)
    {
        self.cookieSource = cookieSource
        self.manualBearerToken = manualBearerToken
        self.organization = organization
        self.apiHost = apiHost
    }

    public func bearerToken(environment: [String: String]) -> String? {
        environment["DEVIN_BEARER_TOKEN"]
            ?? environment["DEVIN_AUTHORIZATION"]
            ?? self.manualBearerToken
    }
}

public enum DevinProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.devin
    public typealias Section = DevinProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias DevinProviderSettings = CodexBarCore.DevinProviderSettings
    public var devin: DevinProviderSettings? {
        self[DevinProviderSettingsKey.self]
    }

    public static func make(devin: DevinProviderSettings?) -> Self {
        self.make(devin, for: DevinProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func devin(_ section: DevinProviderSettings) -> Self {
        Self(section, for: DevinProviderSettingsKey.self)
    }
}
