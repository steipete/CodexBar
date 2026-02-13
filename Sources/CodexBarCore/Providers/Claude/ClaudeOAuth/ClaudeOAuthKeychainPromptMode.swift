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
