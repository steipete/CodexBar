import Foundation

public struct OpenCodeProviderSettings: Sendable {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let workspaceID: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?, workspaceID: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.workspaceID = workspaceID
    }
}

public enum OpenCodeProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.opencode
    public typealias Section = OpenCodeProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias OpenCodeProviderSettings = CodexBarCore.OpenCodeProviderSettings
    public var opencode: OpenCodeProviderSettings? {
        self[OpenCodeProviderSettingsKey.self]
    }

    public static func make(opencode: OpenCodeProviderSettings?) -> Self {
        self.make(opencode, for: OpenCodeProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func opencode(_ section: OpenCodeProviderSettings) -> Self {
        Self(section, for: OpenCodeProviderSettingsKey.self)
    }
}
