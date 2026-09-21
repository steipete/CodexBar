import Foundation

public struct VeniceProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum VeniceProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.venice
    public typealias Section = VeniceProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias VeniceProviderSettings = CodexBarCore.VeniceProviderSettings
    public var venice: VeniceProviderSettings? {
        self[VeniceProviderSettingsKey.self]
    }

    public static func make(venice: VeniceProviderSettings?) -> Self {
        self.make(venice, for: VeniceProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func venice(_ section: VeniceProviderSettings) -> Self {
        Self(section, for: VeniceProviderSettingsKey.self)
    }
}
