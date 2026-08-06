import Foundation

public struct ZoomMateProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum ZoomMateProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.zoommate
    public typealias Section = ZoomMateProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias ZoomMateProviderSettings = CodexBarCore.ZoomMateProviderSettings
    public var zoommate: ZoomMateProviderSettings? {
        self[ZoomMateProviderSettingsKey.self]
    }

    public static func make(zoommate: ZoomMateProviderSettings?) -> Self {
        self.make(zoommate, for: ZoomMateProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func zoommate(_ section: ZoomMateProviderSettings) -> Self {
        Self(section, for: ZoomMateProviderSettingsKey.self)
    }
}
