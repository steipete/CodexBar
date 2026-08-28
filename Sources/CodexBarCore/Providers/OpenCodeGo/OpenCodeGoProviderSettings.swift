import Foundation

public enum OpenCodeGoProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.opencodego
    public typealias Section = OpenCodeProviderSettings
}

extension ProviderSettingsSnapshot {
    public var opencodego: OpenCodeProviderSettings? {
        self[OpenCodeGoProviderSettingsKey.self]
    }

    public static func make(opencodego: OpenCodeProviderSettings?) -> Self {
        self.make(opencodego, for: OpenCodeGoProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func opencodego(_ section: OpenCodeProviderSettings) -> Self {
        Self(section, for: OpenCodeGoProviderSettingsKey.self)
    }
}
