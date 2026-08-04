import Foundation

public struct JetBrainsProviderSettings: Sendable {
    public let ideBasePath: String?

    public init(ideBasePath: String?) {
        self.ideBasePath = ideBasePath
    }
}

public enum JetBrainsProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.jetbrains
    public typealias Section = JetBrainsProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias JetBrainsProviderSettings = CodexBarCore.JetBrainsProviderSettings
    public var jetbrains: JetBrainsProviderSettings? {
        self[JetBrainsProviderSettingsKey.self]
    }

    public var jetbrainsIDEBasePath: String? {
        self.jetbrains?.ideBasePath
    }

    public static func make(jetbrains: JetBrainsProviderSettings?) -> Self {
        self.make(jetbrains, for: JetBrainsProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func jetbrains(_ section: JetBrainsProviderSettings) -> Self {
        Self(section, for: JetBrainsProviderSettingsKey.self)
    }
}
