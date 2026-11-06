import Foundation

public struct WorkBuddyProviderSettings: Sendable {
    public let cookies: CookieProviderSettings
    public let manualUserAgent: String?

    public init(cookies: CookieProviderSettings, manualUserAgent: String? = nil) {
        self.cookies = cookies
        self.manualUserAgent = manualUserAgent
    }
}

extension ProviderConfig {
    public var workBuddyUserAgent: String? {
        get { self.extensionValue(forKey: "workBuddyUserAgent") }
        set { self.setExtensionValue(newValue, forKey: "workBuddyUserAgent") }
    }
}

public enum WorkBuddyProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.workbuddy
    public typealias Section = WorkBuddyProviderSettings
}

extension ProviderSettingsSnapshot {
    public var workbuddy: WorkBuddyProviderSettings? {
        self[WorkBuddyProviderSettingsKey.self]
    }

    public static func make(workbuddy: WorkBuddyProviderSettings?) -> Self {
        self.make(workbuddy, for: WorkBuddyProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func workbuddy(_ section: WorkBuddyProviderSettings) -> Self {
        Self(section, for: WorkBuddyProviderSettingsKey.self)
    }
}
