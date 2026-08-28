import Foundation

public struct LongCatProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum LongCatProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.longcat
    public typealias Section = LongCatProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias LongCatProviderSettings = CodexBarCore.LongCatProviderSettings
    public var longcat: LongCatProviderSettings? {
        self[LongCatProviderSettingsKey.self]
    }

    public static func make(longcat: LongCatProviderSettings?) -> Self {
        self.make(longcat, for: LongCatProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func longcat(_ section: LongCatProviderSettings) -> Self {
        Self(section, for: LongCatProviderSettingsKey.self)
    }
}
