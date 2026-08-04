import Foundation

public struct CursorProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum CursorProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.cursor
    public typealias Section = CursorProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias CursorProviderSettings = CodexBarCore.CursorProviderSettings
    public var cursor: CursorProviderSettings? {
        self[CursorProviderSettingsKey.self]
    }

    public static func make(cursor: CursorProviderSettings?) -> Self {
        self.make(cursor, for: CursorProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func cursor(_ section: CursorProviderSettings) -> Self {
        Self(section, for: CursorProviderSettingsKey.self)
    }
}
