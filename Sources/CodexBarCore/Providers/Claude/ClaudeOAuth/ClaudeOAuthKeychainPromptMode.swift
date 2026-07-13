import Foundation

public enum ClaudeOAuthKeychainPromptMode: String, Sendable, Codable, CaseIterable {
    case never
    case onlyOnUserAction
    case always
}

public enum ClaudeOAuthKeychainPromptPreference {
    static let releaseApplicationDefaultsDomain = "com.steipete.codexbar"
    static let debugApplicationDefaultsDomain = "com.steipete.codexbar.debug"
    private static let userDefaultsKey = "claudeOAuthKeychainPromptMode"

    static var applicationDefaultsDomain: String {
        self.resolveApplicationDefaultsDomain(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL,
            invocationURL: CommandLine.arguments.first.map(URL.init(fileURLWithPath:)))
    }

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

    static func resolveApplicationDefaultsDomain(
        bundleIdentifier: String?,
        bundleURL: URL?,
        executableURL: URL?,
        invocationURL: URL?,
        bundleIdentifierForApp: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) -> String
    {
        if let domain = self.defaultsDomain(forBundleIdentifier: bundleIdentifier) {
            return domain
        }

        let candidates = [bundleURL, executableURL, invocationURL].compactMap(\.self)
        var visitedPaths = Set<String>()
        for candidate in candidates {
            var current = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let ancestorCount = current.pathComponents.count
            for _ in 0..<ancestorCount {
                if current.pathExtension == "app",
                   visitedPaths.insert(current.path).inserted,
                   let domain = self.defaultsDomain(forBundleIdentifier: bundleIdentifierForApp(current))
                {
                    return domain
                }
                current.deleteLastPathComponent()
            }
        }
        return self.releaseApplicationDefaultsDomain
    }

    private static func defaultsDomain(forBundleIdentifier bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        // Check debug first because its identifier is a child of the release identifier.
        if bundleIdentifier == self.debugApplicationDefaultsDomain
            || bundleIdentifier.hasPrefix("\(self.debugApplicationDefaultsDomain).")
        {
            return self.debugApplicationDefaultsDomain
        }
        if bundleIdentifier == self.releaseApplicationDefaultsDomain
            || bundleIdentifier.hasPrefix("\(self.releaseApplicationDefaultsDomain).")
        {
            return self.releaseApplicationDefaultsDomain
        }
        return nil
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
