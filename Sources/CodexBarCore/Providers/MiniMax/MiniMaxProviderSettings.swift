import Foundation

public struct MiniMaxProviderSettings: Sendable {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let apiRegion: MiniMaxAPIRegion

    public init(
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String?,
        apiRegion: MiniMaxAPIRegion = .global)
    {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.apiRegion = apiRegion
    }
}

public enum MiniMaxProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.minimax
    public typealias Section = MiniMaxProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias MiniMaxProviderSettings = CodexBarCore.MiniMaxProviderSettings
    public var minimax: MiniMaxProviderSettings? {
        self[MiniMaxProviderSettingsKey.self]
    }

    public static func make(minimax: MiniMaxProviderSettings?) -> Self {
        self.make(minimax, for: MiniMaxProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func minimax(_ section: MiniMaxProviderSettings) -> Self {
        Self(section, for: MiniMaxProviderSettingsKey.self)
    }
}
