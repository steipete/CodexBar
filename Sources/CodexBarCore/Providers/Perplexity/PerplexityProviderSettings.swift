import Foundation

public struct PerplexityProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum PerplexityProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.perplexity
    public typealias Section = PerplexityProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias PerplexityProviderSettings = CodexBarCore.PerplexityProviderSettings
    public var perplexity: PerplexityProviderSettings? {
        self[PerplexityProviderSettingsKey.self]
    }

    public static func make(perplexity: PerplexityProviderSettings?) -> Self {
        self.make(perplexity, for: PerplexityProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func perplexity(_ section: PerplexityProviderSettings) -> Self {
        Self(section, for: PerplexityProviderSettingsKey.self)
    }
}
