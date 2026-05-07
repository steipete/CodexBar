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
        if let raw = userDefaults.string(forKey: self.userDefaultsKey) {
            return ClaudeOAuthKeychainReadStrategy(rawValue: raw) ?? .securityFramework
        }
        #if DEBUG
        if self.isRunningUnderTests,
           ProcessInfo.processInfo.environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        {
            return .securityFramework
        }
        #endif
        return .securityCLIExperimental
    }

    #if DEBUG
    private static var isRunningUnderTests: Bool {
        let processName = ProcessInfo.processInfo.processName
        return processName == "swiftpm-testing-helper"
            || processName.hasSuffix("PackageTests")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    public static func withTaskOverrideForTesting<T>(
        _ strategy: ClaudeOAuthKeychainReadStrategy?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverride.withValue(strategy) {
            try operation()
        }
    }

    public static func withTaskOverrideForTesting<T>(
        _ strategy: ClaudeOAuthKeychainReadStrategy?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverride.withValue(strategy) {
            try await operation()
        }
    }

    public static var currentTaskOverrideForTesting: ClaudeOAuthKeychainReadStrategy? {
        self.taskOverride
    }
    #endif
}
