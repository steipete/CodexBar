import Foundation

public struct ManusProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum ManusProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.manus
    public typealias Section = ManusProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias ManusProviderSettings = CodexBarCore.ManusProviderSettings
    public var manus: ManusProviderSettings? {
        self[ManusProviderSettingsKey.self]
    }

    public static func make(manus: ManusProviderSettings?) -> Self {
        self.make(manus, for: ManusProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func manus(_ section: ManusProviderSettings) -> Self {
        Self(section, for: ManusProviderSettingsKey.self)
    }
}
