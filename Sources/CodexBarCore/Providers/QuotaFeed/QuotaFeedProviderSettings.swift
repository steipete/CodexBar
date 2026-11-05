import Foundation

public struct QuotaFeedProviderSettings: Sendable {
    public let path: String?

    public init(path: String?) { self.path = path }
}

public enum QuotaFeedProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.quotafeed
    public typealias Section = QuotaFeedProviderSettings
}

extension ProviderConfig {
    public var quotaFeedPath: String? {
        get { self.extensionValue(forKey: "quotaFeedPath") }
        set { self.setExtensionValue(newValue, forKey: "quotaFeedPath") }
    }
}
