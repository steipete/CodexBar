import Foundation

public struct DevinProviderSettings: Sendable {
    public let cookieSource: ProviderCookieSource
    public let manualBearerToken: String?
    public let organization: String?

    public init(cookieSource: ProviderCookieSource, manualBearerToken: String?, organization: String?) {
        self.cookieSource = cookieSource
        self.manualBearerToken = manualBearerToken
        self.organization = organization
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
