import Foundation

public enum WorkBuddyProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.workbuddy
    public typealias Section = CookieProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias WorkBuddyProviderSettings = CookieProviderSettings
    public var workbuddy: WorkBuddyProviderSettings? {
        self[WorkBuddyProviderSettingsKey.self]
    }

    public static func make(workbuddy: WorkBuddyProviderSettings?) -> Self {
        self.make(workbuddy, for: WorkBuddyProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func workbuddy(_ section: CookieProviderSettings) -> Self {
        Self(section, for: WorkBuddyProviderSettingsKey.self)
    }
}
