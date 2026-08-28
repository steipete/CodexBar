import Foundation

public struct MiMoProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum MiMoProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.mimo
    public typealias Section = MiMoProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias MiMoProviderSettings = CodexBarCore.MiMoProviderSettings
    public var mimo: MiMoProviderSettings? {
        self[MiMoProviderSettingsKey.self]
    }

    public static func make(mimo: MiMoProviderSettings?) -> Self {
        self.make(mimo, for: MiMoProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func mimo(_ section: MiMoProviderSettings) -> Self {
        Self(section, for: MiMoProviderSettingsKey.self)
    }
}
