import Foundation

public struct AntigravityProviderSettings: Sendable, Equatable {
    public var primaryPoolPreference: AntigravityPrimaryPoolPreference
    public var showCredits: Bool

    public init(
        primaryPoolPreference: AntigravityPrimaryPoolPreference = .auto,
        showCredits: Bool = true)
    {
        self.primaryPoolPreference = primaryPoolPreference
        self.showCredits = showCredits
    }
}

public enum AntigravityProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.antigravity
    public typealias Section = AntigravityProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias AntigravityProviderSettings = CodexBarCore.AntigravityProviderSettings

    public var antigravity: AntigravityProviderSettings? {
        self[AntigravityProviderSettingsKey.self]
    }

    public static func make(antigravity: AntigravityProviderSettings?) -> Self {
        self.make(antigravity, for: AntigravityProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func antigravity(_ section: AntigravityProviderSettings) -> Self {
        Self(section, for: AntigravityProviderSettingsKey.self)
    }
}
