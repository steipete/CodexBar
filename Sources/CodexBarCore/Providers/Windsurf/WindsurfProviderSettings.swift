import Foundation

public struct WindsurfProviderSettings: Sendable {
    public let usageDataSource: WindsurfUsageDataSource
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(
        usageDataSource: WindsurfUsageDataSource,
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String?)
    {
        self.usageDataSource = usageDataSource
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum WindsurfProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.windsurf
    public typealias Section = WindsurfProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias WindsurfProviderSettings = CodexBarCore.WindsurfProviderSettings
    public var windsurf: WindsurfProviderSettings? {
        self[WindsurfProviderSettingsKey.self]
    }

    public static func make(windsurf: WindsurfProviderSettings?) -> Self {
        self.make(windsurf, for: WindsurfProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func windsurf(_ section: WindsurfProviderSettings) -> Self {
        Self(section, for: WindsurfProviderSettingsKey.self)
    }
}
