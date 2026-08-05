import Foundation

public struct FireworksProviderSettings: Sendable {
    public let accountSlug: String?

    public init(accountSlug: String? = nil) {
        self.accountSlug = accountSlug
    }
}

public enum FireworksProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.fireworks
    public typealias Section = FireworksProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias FireworksProviderSettings = CodexBarCore.FireworksProviderSettings
    public var fireworks: FireworksProviderSettings? {
        self[FireworksProviderSettingsKey.self]
    }

    public static func make(fireworks: FireworksProviderSettings?) -> Self {
        self.make(fireworks, for: FireworksProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func fireworks(_ section: FireworksProviderSettings) -> Self {
        Self(section, for: FireworksProviderSettingsKey.self)
    }
}
