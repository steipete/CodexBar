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

    /// Local cost sources only; account credentials and cswap's private metadata are never read.
    public static func costProjectsRoots(
        accountConfigDirectory: String? = nil,
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil) -> [URL]
    {
        if let directory = self.nonemptyLiteral(accountConfigDirectory) {
            return [self.directoryURL(directory, workingDirectory: workingDirectory)
                .appendingPathComponent("projects", isDirectory: true)]
        }
        var pathEnvironment = environment
        if pathEnvironment["HOME"]?.isEmpty ?? true {
            pathEnvironment["HOME"] = homeDirectory.path
        }
        let ownerHome = self.homeDirectory(environment: pathEnvironment, workingDirectory: workingDirectory)
        let configRoot = self.configRoot(environment: pathEnvironment, workingDirectory: workingDirectory)
        var roots = [configRoot.appendingPathComponent("projects", isDirectory: true)]
        if environment[self.configDirectoryEnvironmentKey]?.isEmpty ?? true {
            roots.insert(ownerHome.appendingPathComponent(".config/claude/projects", isDirectory: true), at: 0)
            roots.append(contentsOf: ClaudeDesktopProjectsLocator.roots(
                homeDirectory: ownerHome, fileManager: fileManager))
        }

        let legacy = ownerHome.appendingPathComponent(".claude-swap-backup/sessions", isDirectory: true)
        #if os(Linux)
        let xdg = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? ownerHome.appendingPathComponent(".local/share", isDirectory: true)
        let swapRoots = [legacy, xdg.appendingPathComponent("claude-swap/sessions", isDirectory: true)]
        #else
        let swapRoots = [legacy]
        #endif
        // cswap run stores profiles one level below sessions; shared-history projects may be symlinks.
        for root in swapRoots {
            let slots = (try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for slot in slots.sorted(by: { $0.path < $1.path }) {
                let parts = slot.lastPathComponent.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let number = Int(parts[0]), number > 0 else { continue }
                let projects = slot.appendingPathComponent("projects", isDirectory: true)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: projects.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    roots.append(projects)
                }
            }
        }
        var seen: Set<String> = []
        return roots.map(\.standardizedFileURL).filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
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
