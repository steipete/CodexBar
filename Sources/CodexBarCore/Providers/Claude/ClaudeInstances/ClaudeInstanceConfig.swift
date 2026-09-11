import Foundation

/// One user-configured Claude Code profile: an optional `claude` binary, a `CLAUDE_CONFIG_DIR`, and extra
/// environment variables. CodexBar reads each instance's quota through that instance's own Claude CLI, so Claude
/// Code stays the only reader of the profile's credentials.
public struct ClaudeInstanceConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var binaryPath: String?
    public var configDirectory: String
    public var environment: [String: String]?

    public init(
        id: String = UUID().uuidString,
        name: String,
        binaryPath: String? = nil,
        configDirectory: String,
        environment: [String: String]? = nil)
    {
        self.id = id
        self.name = name
        self.binaryPath = binaryPath
        self.configDirectory = configDirectory
        self.environment = environment
    }

    public var normalizedConfigDirectory: String? {
        ClaudeInstanceEnvironment.normalizedAbsolutePath(self.configDirectory)
    }

    public var normalizedBinaryPath: String? {
        ClaudeInstanceEnvironment.normalizedAbsolutePath(self.binaryPath)
    }
}

public enum ClaudeInstanceEnvironment {
    public static let cliPathEnvironmentKey = "CLAUDE_CLI_PATH"

    /// Keys that would route Claude Code to other credentials. They are dropped from the inherited environment
    /// and cannot be set per instance, so an instance always reads its own profile's login.
    private static let credentialKeys: Set<String> = [
        ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey,
        ClaudeOAuthCredentialsStore.environmentTokenKey,
        ClaudeOAuthCredentialsStore.environmentScopesKey,
        "CLAUDE_CODE_OAUTH_TOKEN",
    ]

    /// Keys owned by the instance's dedicated fields.
    private static let fieldOwnedKeys: Set<String> = [
        ClaudeConfigPaths.configDirectoryEnvironmentKey,
        cliPathEnvironmentKey,
        "HOME",
    ]

    public static func isReservedKey(_ key: String) -> Bool {
        self.isCredentialKey(key) || self.fieldOwnedKeys.contains(key)
    }

    /// POSIX environment variable names: a letter or underscore followed by letters, digits, or underscores.
    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first.isASCII,
              first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar == "_" || CharacterSet.alphanumerics.contains(scalar))
        }
    }

    /// Trimmed, valid, non-reserved variables; everything else is dropped.
    public static func sanitizedVariables(_ variables: [String: String]?) -> [String: String] {
        var result: [String: String] = [:]
        for (rawKey, value) in variables ?? [:] {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.isValidKey(key), !self.isReservedKey(key) else { continue }
            result[key] = value
        }
        return result
    }

    /// Parses `KEY=value` lines. Blank lines, `#` comments, and lines without a valid key are skipped; values keep
    /// everything after the first `=`.
    public static func parseVariables(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard self.isValidKey(key) else { continue }
            result[key] = String(line[line.index(after: separator)...])
        }
        return result
    }

    public static func formatVariables(_ variables: [String: String]?) -> String {
        (variables ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    /// Tilde-expanded, standardized absolute path; nil when empty or relative.
    public static func normalizedAbsolutePath(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// The environment one instance's Claude CLI runs with, or nil when it has no usable config directory.
    public static func environment(
        for instance: ClaudeInstanceConfig,
        base: [String: String]) -> [String: String]?
    {
        guard let configDirectory = instance.normalizedConfigDirectory else { return nil }
        var environment = base
        for key in environment.keys where self.isCredentialKey(key) || key == self.cliPathEnvironmentKey {
            environment.removeValue(forKey: key)
        }
        environment.merge(self.sanitizedVariables(instance.environment)) { _, instanceValue in instanceValue }
        environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] = configDirectory
        if let binaryPath = instance.normalizedBinaryPath {
            environment[self.cliPathEnvironmentKey] = binaryPath
        }
        return environment
    }

    private static func isCredentialKey(_ key: String) -> Bool {
        key.hasPrefix("ANTHROPIC_") || self.credentialKeys.contains(key)
    }
}
