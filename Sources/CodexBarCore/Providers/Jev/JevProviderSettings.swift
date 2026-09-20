import Foundation

public struct JevProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum JevProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.jev
    public typealias Section = JevProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias JevProviderSettings = CodexBarCore.JevProviderSettings

    public var jev: JevProviderSettings? {
        self[JevProviderSettingsKey.self]
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func jev(_ section: JevProviderSettings) -> Self {
        Self(section, for: JevProviderSettingsKey.self)
    }
}
