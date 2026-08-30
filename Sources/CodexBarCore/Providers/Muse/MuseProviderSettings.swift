import Foundation

public struct MuseProviderSettings: Sendable, ProviderCookieSettings {
    public let baseURL: String?
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.baseURL = nil
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }

    public init(
        baseURL: String? = nil,
        cookieSource: ProviderCookieSource = .auto,
        manualCookieHeader: String? = nil)
    {
        self.baseURL = baseURL
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum MuseProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.muse
    public typealias Section = MuseProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias MuseProviderSettings = CodexBarCore.MuseProviderSettings
    public var muse: MuseProviderSettings? {
        self[MuseProviderSettingsKey.self]
    }

    public static func make(muse: MuseProviderSettings?) -> Self {
        self.make(muse, for: MuseProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func muse(_ section: MuseProviderSettings) -> Self {
        Self(section, for: MuseProviderSettingsKey.self)
    }
}
