import Foundation

public struct ReplicateProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum ReplicateProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.replicate
    public typealias Section = ReplicateProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias ReplicateProviderSettings = CodexBarCore.ReplicateProviderSettings
    public var replicate: ReplicateProviderSettings? {
        self[ReplicateProviderSettingsKey.self]
    }

    public static func make(replicate: ReplicateProviderSettings?) -> Self {
        self.make(replicate, for: ReplicateProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func replicate(_ section: ReplicateProviderSettings) -> Self {
        Self(section, for: ReplicateProviderSettingsKey.self)
    }
}
