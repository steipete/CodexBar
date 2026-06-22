import Crypto
import Foundation

/// A Claude login discovered on this machine, expressed as a refreshable
/// `ClaudeCredentialSource` so the fetch path can read AND refresh it per
/// account (rather than all accounts sharing the single default login).
public struct DiscoveredClaudeAccount: Sendable, Equatable {
    public let source: ClaudeCredentialSource
    public let label: String
    public let configDirectory: String

    public init(source: ClaudeCredentialSource, label: String, configDirectory: String) {
        self.source = source
        self.label = label
        self.configDirectory = configDirectory
    }
}

/// Finds the Claude Code logins on this machine by scanning `~/.claude*` config
/// directories — the same layout Clawd Pet enumerates. Each directory maps to
/// either a credentials file or a Keychain service.
///
/// Prompt-safety: discovery only checks directory/file existence and *computes*
/// Keychain service names; it never reads a token, so it cannot trigger a
/// Keychain prompt. The token read (and any prompt) happens later, per account,
/// in `ClaudeCredentialResolver` at fetch time.
public enum ClaudeAccountDiscovery {
    /// Default (no CLAUDE_CONFIG_DIR) Keychain service used by Claude Code.
    public static let defaultKeychainService = "Claude Code-credentials"
    private static let credentialsFileName = ".credentials.json"

    /// Keychain service Claude Code uses for a given config dir. `~/.claude`
    /// uses the bare service; a CLAUDE_CONFIG_DIR uses
    /// `"Claude Code-credentials-" + sha256(absolutePath)[0..<8]` (the scheme
    /// Clawd Pet decodes). The path is hashed verbatim (no symlink resolution)
    /// to match what Claude Code stored.
    public static func keychainServiceName(
        forConfigDirectory configDir: String,
        defaultClaudeDirectory: String) -> String
    {
        if configDir == defaultClaudeDirectory {
            return self.defaultKeychainService
        }
        let suffix = self.sha256Hex(configDir).prefix(8)
        return "\(self.defaultKeychainService)-\(suffix)"
    }

    /// Enumerate Claude logins from `~/.claude*` config directories.
    public static func discover(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default) -> [DiscoveredClaudeAccount]
    {
        let defaultClaudeDir = (homeDirectory as NSString).appendingPathComponent(".claude")
        var seen = Set<String>()
        var accounts: [DiscoveredClaudeAccount] = []
        for dir in self.claudeConfigDirectories(homeDirectory: homeDirectory, fileManager: fileManager) {
            let credsFile = (dir as NSString).appendingPathComponent(self.credentialsFileName)
            let source: ClaudeCredentialSource = fileManager.fileExists(atPath: credsFile)
                ? .credentialsFile(path: credsFile)
                : .keychainService(
                    service: self.keychainServiceName(
                        forConfigDirectory: dir,
                        defaultClaudeDirectory: defaultClaudeDir),
                    account: nil)
            guard seen.insert(source.encodedTokenValue()).inserted else { continue }
            accounts.append(DiscoveredClaudeAccount(
                source: source,
                label: self.label(forConfigDirectory: dir, defaultClaudeDirectory: defaultClaudeDir),
                configDirectory: dir))
        }
        return accounts
    }

    static func claudeConfigDirectories(
        homeDirectory: String,
        fileManager: FileManager) -> [String]
    {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: homeDirectory) else {
            return []
        }
        return entries
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .map { (homeDirectory as NSString).appendingPathComponent($0) }
            .filter { path in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()
    }

    static func label(forConfigDirectory configDir: String, defaultClaudeDirectory: String) -> String {
        if configDir == defaultClaudeDirectory {
            return "Claude"
        }
        let name = (configDir as NSString).lastPathComponent
        if let range = name.range(of: ".claude-") {
            return String(name[range.upperBound...])
        }
        return name
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
