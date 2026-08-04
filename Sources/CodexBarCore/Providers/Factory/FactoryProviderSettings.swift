import Foundation

public struct FactoryProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum FactoryProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.factory
    public typealias Section = FactoryProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias FactoryProviderSettings = CodexBarCore.FactoryProviderSettings
    public var factory: FactoryProviderSettings? {
        self[FactoryProviderSettingsKey.self]
    }

    public static func make(factory: FactoryProviderSettings?) -> Self {
        self.make(factory, for: FactoryProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func factory(_ section: FactoryProviderSettings) -> Self {
        Self(section, for: FactoryProviderSettingsKey.self)
    }
}
