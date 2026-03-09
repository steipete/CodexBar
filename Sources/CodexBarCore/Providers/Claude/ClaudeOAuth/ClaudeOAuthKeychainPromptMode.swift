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
        guard self.isApplicable(readStrategy: readStrategy) else {
            return .always
        }
        return self.storedMode(userDefaults: userDefaults)
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
