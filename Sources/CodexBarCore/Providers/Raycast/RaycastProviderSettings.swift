import Foundation

public enum RaycastProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.raycast
    public typealias Section = CookieProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias RaycastProviderSettings = CookieProviderSettings
    public var raycast: RaycastProviderSettings? {
        self[RaycastProviderSettingsKey.self]
    }

    public static func make(raycast: RaycastProviderSettings?) -> Self {
        self.make(raycast, for: RaycastProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func raycast(_ section: CookieProviderSettings) -> Self {
        Self(section, for: RaycastProviderSettingsKey.self)
    }
}
