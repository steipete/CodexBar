import Foundation

public enum ClaudeOAuthKeychainReadStrategy: String, Sendable, Codable, CaseIterable {
    case securityFramework
    case securityCLIExperimental
}

public enum ClaudeOAuthKeychainReadStrategyPreference {
    private static let userDefaultsKey = "claudeOAuthKeychainReadStrategy"

    #if DEBUG
    @TaskLocal private static var taskOverride: ClaudeOAuthKeychainReadStrategy?
    #endif

    public static func current(userDefaults: UserDefaults = .standard) -> ClaudeOAuthKeychainReadStrategy {
        #if DEBUG
        if let taskOverride { return taskOverride }
        #endif
        if let raw = userDefaults.string(forKey: self.userDefaultsKey),
           let strategy = ClaudeOAuthKeychainReadStrategy(rawValue: raw)
        {
            return strategy
        }
        return .securityFramework
    }

    #if DEBUG
    static func withTaskOverrideForTesting<T>(
        _ strategy: ClaudeOAuthKeychainReadStrategy?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverride.withValue(strategy) {
            try operation()
        }
    }

    static func withTaskOverrideForTesting<T>(
        _ strategy: ClaudeOAuthKeychainReadStrategy?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverride.withValue(strategy) {
            try await operation()
        }
    }
    #endif
}
