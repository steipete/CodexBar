import Foundation

public struct T3ChatProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum T3ChatProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.t3chat
    public typealias Section = T3ChatProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias T3ChatProviderSettings = CodexBarCore.T3ChatProviderSettings
    public var t3chat: T3ChatProviderSettings? {
        self[T3ChatProviderSettingsKey.self]
    }

    public static func make(t3chat: T3ChatProviderSettings?) -> Self {
        self.make(t3chat, for: T3ChatProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func t3chat(_ section: T3ChatProviderSettings) -> Self {
        Self(section, for: T3ChatProviderSettingsKey.self)
    }
}
