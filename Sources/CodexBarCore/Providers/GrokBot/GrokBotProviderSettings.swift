import Foundation

public struct GrokBotProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum GrokBotProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.grokbot
    public typealias Section = GrokBotProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias GrokBotProviderSettings = CodexBarCore.GrokBotProviderSettings
    public var grokbot: GrokBotProviderSettings? {
        self[GrokBotProviderSettingsKey.self]
    }

    public static func make(grokbot: GrokBotProviderSettings?) -> Self {
        self.make(grokbot, for: GrokBotProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func grokbot(_ section: GrokBotProviderSettings) -> Self {
        Self(section, for: GrokBotProviderSettingsKey.self)
    }
}
