import Foundation

public struct KiloProviderSettings: Sendable {
    public let usageDataSource: KiloUsageDataSource
    public let extrasEnabled: Bool

    public init(usageDataSource: KiloUsageDataSource, extrasEnabled: Bool) {
        self.usageDataSource = usageDataSource
        self.extrasEnabled = extrasEnabled
    }
}

public enum KiloProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.kilo
    public typealias Section = KiloProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias KiloProviderSettings = CodexBarCore.KiloProviderSettings
    public var kilo: KiloProviderSettings? {
        self[KiloProviderSettingsKey.self]
    }

    public static func make(kilo: KiloProviderSettings?) -> Self {
        self.make(kilo, for: KiloProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func kilo(_ section: KiloProviderSettings) -> Self {
        Self(section, for: KiloProviderSettingsKey.self)
    }
}
