import Foundation

public struct CommandCodeProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum CommandCodeProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.commandcode
    public typealias Section = CommandCodeProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias CommandCodeProviderSettings = CodexBarCore.CommandCodeProviderSettings
    public var commandcode: CommandCodeProviderSettings? {
        self[CommandCodeProviderSettingsKey.self]
    }

    public static func make(commandcode: CommandCodeProviderSettings?) -> Self {
        self.make(commandcode, for: CommandCodeProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func commandcode(_ section: CommandCodeProviderSettings) -> Self {
        Self(section, for: CommandCodeProviderSettingsKey.self)
    }
}
