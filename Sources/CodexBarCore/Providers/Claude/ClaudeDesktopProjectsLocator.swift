import Foundation

public enum ClaudeDesktopProjectsLocator {
    private static let sessionDirectoryNames = [
        "local-agent-mode-sessions",
        "claude-code-sessions",
    ]

    private static let skippedDirectoryNames = Set([
        ".build",
        ".git",
        "build",
        "DerivedData",
        "node_modules",
        "outputs",
        "target",
    ])

    public static func roots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) -> [URL]
    {
        let claudeApplicationSupport = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
        let sessionRoots = self.sessionDirectoryNames.map {
            claudeApplicationSupport.appendingPathComponent($0, isDirectory: true)
        }

        var roots: [URL] = []
        var queue = sessionRoots.map { (url: $0, depth: 0) }
        var visited = Set(sessionRoots.map(\.standardizedFileURL.path))
        var nextIndex = 0
        // Current Desktop entries under claude-code-sessions are metadata whose cliSessionId maps to the
        // shared ~/.claude/projects logs. Seed that root anyway so embedded project stores are found when present.
        // Covers observed Desktop layouts through account/workspace, session, agent, and local_agent
        // without descending into arbitrary checked-out workspaces.
        let maxDepth = 4

        while nextIndex < queue.count {
            let current = queue[nextIndex]
            nextIndex += 1
            if let projects = self.projectsRoot(under: current.url, fileManager: fileManager) {
                roots.append(projects)
            }

            guard current.depth < maxDepth else { continue }
            for child in self.childDirectories(at: current.url, fileManager: fileManager) {
                let standardized = child.standardizedFileURL
                guard visited.insert(standardized.path).inserted else { continue }
                queue.append((standardized, current.depth + 1))
            }
        }
        return roots
    }

    private static func projectsRoot(under base: URL, fileManager: FileManager) -> URL? {
        let projects = base
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projects.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return projects.standardizedFileURL
    }

    private static func childDirectories(at url: URL, fileManager: FileManager) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            return []
        }

        return children.compactMap { child in
            guard !self.skippedDirectoryNames.contains(child.lastPathComponent) else { return nil }
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isDirectory == true
            else {
                return nil
            }
            return child
        }
    }
}
