import Foundation

public struct TypeSafeProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum TypeSafeProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.typesafe
    public typealias Section = TypeSafeProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias TypeSafeProviderSettings = CodexBarCore.TypeSafeProviderSettings
    public var typesafe: TypeSafeProviderSettings? {
        self[TypeSafeProviderSettingsKey.self]
    }

    public static func make(typesafe: TypeSafeProviderSettings?) -> Self {
        self.make(typesafe, for: TypeSafeProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func typesafe(_ section: TypeSafeProviderSettings) -> Self {
        Self(section, for: TypeSafeProviderSettingsKey.self)
    }
}
