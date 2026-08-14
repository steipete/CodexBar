import Foundation

public struct MuseProviderSettings: Sendable {
    public let baseURL: String?

    public init(baseURL: String? = nil) {
        self.baseURL = baseURL
    }
}

public enum MuseProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.muse
    public typealias Section = MuseProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias MuseProviderSettings = CodexBarCore.MuseProviderSettings
    public var muse: MuseProviderSettings? {
        self[MuseProviderSettingsKey.self]
    }

    public static func make(muse: MuseProviderSettings?) -> Self {
        self.make(muse, for: MuseProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func muse(_ section: MuseProviderSettings) -> Self {
        Self(section, for: MuseProviderSettingsKey.self)
    }
}
