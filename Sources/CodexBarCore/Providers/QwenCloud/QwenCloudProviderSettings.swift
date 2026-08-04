import Foundation

public struct QwenCloudProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource = .auto, manualCookieHeader: String? = nil) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum QwenCloudProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.qwencloud
    public typealias Section = QwenCloudProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias QwenCloudProviderSettings = CodexBarCore.QwenCloudProviderSettings
    public var qwenCloud: QwenCloudProviderSettings? {
        self[QwenCloudProviderSettingsKey.self]
    }

    public static func make(qwenCloud: QwenCloudProviderSettings?) -> Self {
        self.make(qwenCloud, for: QwenCloudProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func qwenCloud(_ section: QwenCloudProviderSettings) -> Self {
        Self(section, for: QwenCloudProviderSettingsKey.self)
    }
}
