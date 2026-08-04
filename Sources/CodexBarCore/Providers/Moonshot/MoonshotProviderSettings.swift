import Foundation

public struct MoonshotProviderSettings: Sendable {
    public let region: MoonshotRegion?

    public init(region: MoonshotRegion? = nil) {
        self.region = region
    }
}

public enum MoonshotProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.moonshot
    public typealias Section = MoonshotProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias MoonshotProviderSettings = CodexBarCore.MoonshotProviderSettings
    public var moonshot: MoonshotProviderSettings? {
        self[MoonshotProviderSettingsKey.self]
    }

    public static func make(moonshot: MoonshotProviderSettings?) -> Self {
        self.make(moonshot, for: MoonshotProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func moonshot(_ section: MoonshotProviderSettings) -> Self {
        Self(section, for: MoonshotProviderSettingsKey.self)
    }
}
