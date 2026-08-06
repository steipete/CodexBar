import Foundation

public struct ZaiProviderSettings: Sendable {
    public let apiRegion: ZaiAPIRegion
    public let usageScope: ZaiUsageScope
    public let teamContext: ZaiBigModelTeamContext?

    public init(
        apiRegion: ZaiAPIRegion = .global,
        usageScope: ZaiUsageScope = .personal,
        teamContext: ZaiBigModelTeamContext? = nil)
    {
        self.apiRegion = apiRegion
        self.usageScope = usageScope
        self.teamContext = teamContext
    }
}

public enum ZaiProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.zai
    public typealias Section = ZaiProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias ZaiProviderSettings = CodexBarCore.ZaiProviderSettings
    public var zai: ZaiProviderSettings? {
        self[ZaiProviderSettingsKey.self]
    }

    public static func make(zai: ZaiProviderSettings?) -> Self {
        self.make(zai, for: ZaiProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func zai(_ section: ZaiProviderSettings) -> Self {
        Self(section, for: ZaiProviderSettingsKey.self)
    }
}
