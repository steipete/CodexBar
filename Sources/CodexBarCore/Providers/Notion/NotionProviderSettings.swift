import Foundation

/// Deliberately not a `ProviderCookieSettings`: that protocol's initializer takes only the two
/// cookie fields, so conforming would let generic construction silently drop `workspaceID`.
public struct NotionProviderSettings: Sendable {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let workspaceID: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?, workspaceID: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.workspaceID = workspaceID
    }
}

public enum NotionProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.notion
    public typealias Section = NotionProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias NotionProviderSettings = CodexBarCore.NotionProviderSettings
    public var notion: NotionProviderSettings? {
        self[NotionProviderSettingsKey.self]
    }

    public static func make(notion: NotionProviderSettings?) -> Self {
        self.make(notion, for: NotionProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func notion(_ section: NotionProviderSettings) -> Self {
        Self(section, for: NotionProviderSettingsKey.self)
    }
}
