import Foundation

public struct GrokProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum GrokProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.grok
    public typealias Section = GrokProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias GrokProviderSettings = CodexBarCore.GrokProviderSettings
    public var grok: GrokProviderSettings? {
        self[GrokProviderSettingsKey.self]
    }

    public static func make(grok: GrokProviderSettings?) -> Self {
        self.make(grok, for: GrokProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func grok(_ section: GrokProviderSettings) -> Self {
        Self(section, for: GrokProviderSettingsKey.self)
    }
}
