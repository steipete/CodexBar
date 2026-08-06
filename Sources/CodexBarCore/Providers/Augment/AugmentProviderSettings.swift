import Foundation

public struct AugmentProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum AugmentProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.augment
    public typealias Section = AugmentProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias AugmentProviderSettings = CodexBarCore.AugmentProviderSettings
    public var augment: AugmentProviderSettings? {
        self[AugmentProviderSettingsKey.self]
    }

    public static func make(augment: AugmentProviderSettings?) -> Self {
        self.make(augment, for: AugmentProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func augment(_ section: AugmentProviderSettings) -> Self {
        Self(section, for: AugmentProviderSettingsKey.self)
    }
}
