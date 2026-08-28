import Foundation

/// Resolves Claude-owned files from the fetch environment, matching Claude Code's profile boundary.
public enum ClaudeConfigPaths {
    public static let configDirectoryEnvironmentKey = "CLAUDE_CONFIG_DIR"
    public static let secureStorageDirectoryEnvironmentKey = "CLAUDE_SECURESTORAGE_CONFIG_DIR"

    /// Claude treats `CLAUDE_CONFIG_DIR` as one literal directory. Empty means the default `~/.claude` root.
    public static func configRoot(
        environment: [String: String],
        workingDirectory: URL? = nil) -> URL
    {
        if let configuredRoot = self.nonemptyLiteral(environment[self.configDirectoryEnvironmentKey]) {
            return self.directoryURL(configuredRoot, workingDirectory: workingDirectory)
        }
        return self.defaultConfigRoot(environment: environment, workingDirectory: workingDirectory)
    }

    public static func accountConfigURL(
        environment: [String: String],
        workingDirectory: URL? = nil) -> URL
    {
        let root = self.configRoot(environment: environment, workingDirectory: workingDirectory)
        let profileConfig = root.appendingPathComponent(".config.json")
        if FileManager.default.fileExists(atPath: profileConfig.path) {
            return profileConfig
        }

        if self.nonemptyLiteral(environment[self.configDirectoryEnvironmentKey]) != nil {
            return root.appendingPathComponent(".claude.json")
        }
        return self.homeDirectory(environment: environment, workingDirectory: workingDirectory)
            .appendingPathComponent(".claude.json")
    }

    public static func credentialsURL(
        environment: [String: String],
        workingDirectory: URL? = nil) -> URL
    {
        let root: URL = if let secureStorageRoot = environment[self.secureStorageDirectoryEnvironmentKey] {
            if secureStorageRoot.isEmpty {
                self.defaultConfigRoot(environment: environment, workingDirectory: workingDirectory)
            } else {
                self.directoryURL(secureStorageRoot, workingDirectory: workingDirectory)
            }
        } else {
            self.configRoot(environment: environment, workingDirectory: workingDirectory)
        }
        return root.appendingPathComponent(".credentials.json")
    }

    public static func homeDirectory(
        environment: [String: String],
        workingDirectory: URL? = nil) -> URL
    {
        if let rawHome = self.nonemptyLiteral(environment["HOME"]) {
            return self.directoryURL(rawHome, workingDirectory: workingDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    private static func defaultConfigRoot(
        environment: [String: String],
        workingDirectory: URL?) -> URL
    {
        self.homeDirectory(environment: environment, workingDirectory: workingDirectory)
            .appendingPathComponent(".claude", isDirectory: true)
    }

    private static func nonemptyLiteral(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func directoryURL(_ path: String, workingDirectory: URL?) -> URL {
        // `NSString.isAbsolutePath` treats `~/...` as absolute and Foundation expands it. Claude receives the
        // environment value directly, so only a leading POSIX slash is absolute here.
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        // Claude resolves literal relative profile roots against its process CWD. All CodexBar-owned Claude
        // subprocesses run from this dedicated probe directory, so resolve plain-text profile evidence there too.
        // `appendingPathComponent` intentionally keeps `~` literal instead of applying shell-style expansion.
        let base = workingDirectory ?? ClaudeStatusProbe.probeWorkingDirectoryURL()
        return base.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}
