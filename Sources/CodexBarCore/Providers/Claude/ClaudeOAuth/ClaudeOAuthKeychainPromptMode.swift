import Foundation

public enum ClaudeOAuthKeychainPromptMode: String, Sendable, Codable, CaseIterable {
    case never
    case onlyOnUserAction
    case always
}

public enum ClaudeOAuthKeychainPromptPreference {
    private static let userDefaultsKey = "claudeOAuthKeychainPromptMode"

    #if DEBUG
    @TaskLocal private static var taskOverride: ClaudeOAuthKeychainPromptMode?
    #endif

    public static func current(userDefaults: UserDefaults = .standard) -> ClaudeOAuthKeychainPromptMode {
        self.effectiveMode(userDefaults: userDefaults)
    }

    public static func storedMode(userDefaults: UserDefaults = .standard) -> ClaudeOAuthKeychainPromptMode {
        #if DEBUG
        if let taskOverride { return taskOverride }
        #endif
        if let raw = userDefaults.string(forKey: self.userDefaultsKey),
           let mode = ClaudeOAuthKeychainPromptMode(rawValue: raw)
        {
            return mode
        }
        return .onlyOnUserAction
    }

    public static func isApplicable(
        readStrategy: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current()) -> Bool
    {
        readStrategy == .securityFramework
    }

    public static func effectiveMode(
        userDefaults: UserDefaults = .standard,
        readStrategy: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current())
        -> ClaudeOAuthKeychainPromptMode
    {
        let stored = self.storedMode(userDefaults: userDefaults)
        // Always honor an explicit opt-out. When set to `.never`, no Security.framework keychain queries
        // should run — including fingerprint/sync probes — regardless of the read strategy. This prevents
        // macOS XARA partition-check dialogs that `kSecUseAuthenticationUIFail` cannot suppress.
        if stored == .never { return .never }
        guard self.isApplicable(readStrategy: readStrategy) else {
            return .always
        }
        return stored
    }

    public static func securityFrameworkFallbackMode(
        userDefaults: UserDefaults = .standard,
        readStrategy: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current())
        -> ClaudeOAuthKeychainPromptMode
    {
        if readStrategy == .securityCLIExperimental {
            return self.storedMode(userDefaults: userDefaults)
        }
        return self.effectiveMode(userDefaults: userDefaults, readStrategy: readStrategy)
    }

    #if DEBUG
    static func withTaskOverrideForTesting<T>(
        _ mode: ClaudeOAuthKeychainPromptMode?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverride.withValue(mode) {
            try operation()
        }
    }

    static func withTaskOverrideForTesting<T>(
        _ mode: ClaudeOAuthKeychainPromptMode?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverride.withValue(mode) {
            try await operation()
        }
    }
    #endif
}
