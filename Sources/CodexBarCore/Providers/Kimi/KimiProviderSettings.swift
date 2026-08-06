import Foundation

public struct KimiProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum KimiProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.kimi
    public typealias Section = KimiProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias KimiProviderSettings = CodexBarCore.KimiProviderSettings
    public var kimi: KimiProviderSettings? {
        self[KimiProviderSettingsKey.self]
    }

    public static func make(kimi: KimiProviderSettings?) -> Self {
        self.make(kimi, for: KimiProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func kimi(_ section: KimiProviderSettings) -> Self {
        Self(section, for: KimiProviderSettingsKey.self)
    }
}
