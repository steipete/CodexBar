import Foundation

public enum ClaudeOAuthKeychainPromptMode: String, Sendable, Codable, CaseIterable {
    case never
    case onlyOnUserAction
    case always
}

public enum ClaudeOAuthKeychainPromptPreference {
    static let applicationDefaultsDomain = "com.steipete.codexbar"
    private static let userDefaultsKey = "claudeOAuthKeychainPromptMode"

    #if DEBUG
    private final class UserDefaultsBox: @unchecked Sendable {
        let value: UserDefaults

        init(_ value: UserDefaults) {
            self.value = value
        }
    }

    @TaskLocal private static var taskOverride: ClaudeOAuthKeychainPromptMode?
    @TaskLocal private static var taskApplicationUserDefaultsOverride: UserDefaultsBox?
    #endif

    public static func current(userDefaults: UserDefaults? = nil) -> ClaudeOAuthKeychainPromptMode {
        self.effectiveMode(userDefaults: userDefaults)
    }

    public static func storedMode(userDefaults: UserDefaults? = nil) -> ClaudeOAuthKeychainPromptMode {
        #if DEBUG
        if let taskOverride {
            return taskOverride
        }
        #endif
        let userDefaults = userDefaults ?? self.applicationUserDefaults
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
        userDefaults: UserDefaults? = nil,
        readStrategy: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current())
        -> ClaudeOAuthKeychainPromptMode
    {
        guard self.isApplicable(readStrategy: readStrategy) else {
            return .always
        }
        return self.storedMode(userDefaults: userDefaults)
    }

    public static func securityFrameworkFallbackMode(
        userDefaults: UserDefaults? = nil,
        readStrategy: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current())
        -> ClaudeOAuthKeychainPromptMode
    {
        if readStrategy == .securityCLIExperimental {
            return self.storedMode(userDefaults: userDefaults)
        }
        return self.effectiveMode(userDefaults: userDefaults, readStrategy: readStrategy)
    }

    static var applicationUserDefaults: UserDefaults {
        #if DEBUG
        if let taskApplicationUserDefaultsOverride {
            return taskApplicationUserDefaultsOverride.value
        }
        #endif
        return UserDefaults(suiteName: self.applicationDefaultsDomain) ?? .standard
    }

    #if DEBUG
    public static func withTaskOverrideForTesting<T>(
        _ mode: ClaudeOAuthKeychainPromptMode?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverride.withValue(mode) {
            try operation()
        }
    }

    public static func withTaskOverrideForTesting<T>(
        _ mode: ClaudeOAuthKeychainPromptMode?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverride.withValue(mode) {
            try await operation()
        }
    }

    public static var currentTaskOverrideForTesting: ClaudeOAuthKeychainPromptMode? {
        self.taskOverride
    }

    static func withApplicationUserDefaultsOverrideForTesting<T>(
        _ userDefaults: UserDefaults?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskApplicationUserDefaultsOverride.withValue(userDefaults.map(UserDefaultsBox.init)) {
            try operation()
        }
    }

    static func withApplicationUserDefaultsOverrideForTesting<T>(
        _ userDefaults: UserDefaults?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskApplicationUserDefaultsOverride.withValue(userDefaults.map(UserDefaultsBox.init)) {
            try await operation()
        }
    }
    #endif
}
