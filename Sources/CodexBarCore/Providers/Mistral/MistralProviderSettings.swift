import Foundation

public struct MistralProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum MistralProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.mistral
    public typealias Section = MistralProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias MistralProviderSettings = CodexBarCore.MistralProviderSettings
    public var mistral: MistralProviderSettings? {
        self[MistralProviderSettingsKey.self]
    }

    public static func make(mistral: MistralProviderSettings?) -> Self {
        self.make(mistral, for: MistralProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func mistral(_ section: MistralProviderSettings) -> Self {
        Self(section, for: MistralProviderSettingsKey.self)
    }
}
