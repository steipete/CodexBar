import Foundation

public struct AuditSettingsSnapshot: Sendable, Equatable {
    public let modeEnabled: Bool
    public let networkEnabled: Bool
    public let commandEnabled: Bool
    public let secretEnabled: Bool

    public init(
        modeEnabled: Bool,
        networkEnabled: Bool,
        commandEnabled: Bool,
        secretEnabled: Bool)
    {
        self.modeEnabled = modeEnabled
        self.networkEnabled = networkEnabled
        self.commandEnabled = commandEnabled
        self.secretEnabled = secretEnabled
    }

    public func isEnabled(for category: AuditCategory) -> Bool {
        guard self.modeEnabled else { return false }
        if self.usesImplicitAllCategories {
            return true
        }
        return switch category {
        case .network:
            self.networkEnabled
        case .command:
            self.commandEnabled
        case .secret:
            self.secretEnabled
        }
    }

    public var usesImplicitAllCategories: Bool {
        self.modeEnabled && !self.networkEnabled && !self.commandEnabled && !self.secretEnabled
    }
}

public enum AuditSettings {
    public static let appGroupSuiteName = "group.com.steipete.codexbar"
    public static let modeEnabledKey = "governanceAuditModeEnabled"
    public static let networkEnabledKey = "governanceAuditNetworkRequestsEnabled"
    public static let commandEnabledKey = "governanceAuditCommandExecutionEnabled"
    public static let secretEnabledKey = "governanceAuditSecretAccessEnabled"

    public static func current(
        userDefaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: AuditSettings.appGroupSuiteName))
        -> AuditSettingsSnapshot
    {
        let modeEnabled = self.bool(forKey: self.modeEnabledKey, userDefaults: userDefaults, sharedDefaults: sharedDefaults)
        let networkEnabled = self.bool(
            forKey: self.networkEnabledKey,
            userDefaults: userDefaults,
            sharedDefaults: sharedDefaults)
        let commandEnabled = self.bool(
            forKey: self.commandEnabledKey,
            userDefaults: userDefaults,
            sharedDefaults: sharedDefaults)
        let secretEnabled = self.bool(
            forKey: self.secretEnabledKey,
            userDefaults: userDefaults,
            sharedDefaults: sharedDefaults)
        let effective = self.effectiveCategories(
            modeEnabled: modeEnabled,
            networkEnabled: networkEnabled,
            commandEnabled: commandEnabled,
            secretEnabled: secretEnabled)

        return AuditSettingsSnapshot(
            modeEnabled: modeEnabled,
            networkEnabled: effective.networkEnabled,
            commandEnabled: effective.commandEnabled,
            secretEnabled: effective.secretEnabled)
    }

    private static func bool(
        forKey key: String,
        userDefaults: UserDefaults,
        sharedDefaults: UserDefaults?)
        -> Bool
    {
        if let value = userDefaults.object(forKey: key) as? Bool {
            return value
        }
        if let value = sharedDefaults?.object(forKey: key) as? Bool {
            return value
        }
        return false
    }

    private static func effectiveCategories(
        modeEnabled: Bool,
        networkEnabled: Bool,
        commandEnabled: Bool,
        secretEnabled: Bool)
        -> (networkEnabled: Bool, commandEnabled: Bool, secretEnabled: Bool)
    {
        guard modeEnabled else {
            return (networkEnabled, commandEnabled, secretEnabled)
        }
        guard !networkEnabled && !commandEnabled && !secretEnabled else {
            return (networkEnabled, commandEnabled, secretEnabled)
        }
        return (true, true, true)
    }
}
