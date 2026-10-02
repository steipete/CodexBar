import Foundation

public struct LangdockProviderSettings: Sendable {
    /// SweetCookieKit's stable Edge profile identifier (the profile directory path).
    public let edgeProfileID: String?

    public init(edgeProfileID: String?) {
        self.edgeProfileID = edgeProfileID?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum LangdockProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.langdock
    public typealias Section = LangdockProviderSettings
}

extension ProviderConfig {
    public var langdockEdgeProfileID: String? {
        get { self.extensionValue(forKey: "langdockEdgeProfileID") }
        set { self.setExtensionValue(newValue, forKey: "langdockEdgeProfileID") }
    }
}

extension ProviderSettingsSnapshot {
    public var langdock: LangdockProviderSettings? {
        self[LangdockProviderSettingsKey.self]
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func langdock(_ section: LangdockProviderSettings) -> Self {
        Self(section, for: LangdockProviderSettingsKey.self)
    }
}
