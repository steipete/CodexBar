import Foundation

public struct OllamaProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum OllamaProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.ollama
    public typealias Section = OllamaProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias OllamaProviderSettings = CodexBarCore.OllamaProviderSettings
    public var ollama: OllamaProviderSettings? {
        self[OllamaProviderSettingsKey.self]
    }

    public static func make(ollama: OllamaProviderSettings?) -> Self {
        self.make(ollama, for: OllamaProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func ollama(_ section: OllamaProviderSettings) -> Self {
        Self(section, for: OllamaProviderSettingsKey.self)
    }
}
