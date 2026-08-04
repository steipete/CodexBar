import Foundation

public struct AmpProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum AmpProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.amp
    public typealias Section = AmpProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias AmpProviderSettings = CodexBarCore.AmpProviderSettings
    public var amp: AmpProviderSettings? {
        self[AmpProviderSettingsKey.self]
    }

    public static func make(amp: AmpProviderSettings?) -> Self {
        self.make(amp, for: AmpProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func amp(_ section: AmpProviderSettings) -> Self {
        Self(section, for: AmpProviderSettingsKey.self)
    }
}
