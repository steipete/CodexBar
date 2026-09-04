import Foundation

public struct HelmcodeProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum HelmcodeProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.helmcode
    public typealias Section = HelmcodeProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias HelmcodeProviderSettings = CodexBarCore.HelmcodeProviderSettings

    public var helmcode: HelmcodeProviderSettings? {
        self[HelmcodeProviderSettingsKey.self]
    }

    public static func make(helmcode: HelmcodeProviderSettings?) -> Self {
        self.make(helmcode, for: HelmcodeProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func helmcode(_ section: HelmcodeProviderSettings) -> Self {
        Self(section, for: HelmcodeProviderSettingsKey.self)
    }
}
