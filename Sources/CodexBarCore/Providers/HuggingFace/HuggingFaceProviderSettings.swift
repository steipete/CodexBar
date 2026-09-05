import Foundation

public struct HuggingFaceProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum HuggingFaceProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.huggingface
    public typealias Section = HuggingFaceProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias HuggingFaceProviderSettings = CodexBarCore.HuggingFaceProviderSettings

    public var huggingface: HuggingFaceProviderSettings? {
        self[HuggingFaceProviderSettingsKey.self]
    }

    public static func make(huggingface: HuggingFaceProviderSettings?) -> Self {
        self.make(huggingface, for: HuggingFaceProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func huggingface(_ section: HuggingFaceProviderSettings) -> Self {
        Self(section, for: HuggingFaceProviderSettingsKey.self)
    }
}
