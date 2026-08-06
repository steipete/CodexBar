import Foundation

public struct AbacusProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum AbacusProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.abacus
    public typealias Section = AbacusProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias AbacusProviderSettings = CodexBarCore.AbacusProviderSettings
    public var abacus: AbacusProviderSettings? {
        self[AbacusProviderSettingsKey.self]
    }

    public static func make(abacus: AbacusProviderSettings?) -> Self {
        self.make(abacus, for: AbacusProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func abacus(_ section: AbacusProviderSettings) -> Self {
        Self(section, for: AbacusProviderSettingsKey.self)
    }
}
