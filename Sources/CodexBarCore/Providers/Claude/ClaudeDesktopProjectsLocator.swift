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
        fileManager: FileManager = .default,
        includeAuditFiles: Bool = false) -> [URL]
    {
        var budget = DirectoryMetadataScanBudget(maxEntryCount: .max, maxDepth: 4, timeLimit: .infinity)
        return self.roots(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            budget: &budget,
            includeAuditFiles: includeAuditFiles)
    }

    static func roots(
        homeDirectory: URL,
        fileManager: FileManager,
        budget: inout DirectoryMetadataScanBudget,
        includeAuditFiles: Bool = false) -> [URL]
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
        while nextIndex < queue.count, budget.hasTimeRemaining() {
            let current = queue[nextIndex]
            nextIndex += 1
            if let projects = self.projectsRoot(under: current.url, fileManager: fileManager) {
                roots.append(projects)
            }

            // Audit files are cost inputs, not project roots for live-session correlation.
            let audit = current.url.appendingPathComponent("audit.jsonl")
            if includeAuditFiles,
               let values = try? audit.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true
            {
                roots.append(audit.standardizedFileURL)
            }

            guard current.depth < budget.maxDepth else { continue }
            for child in budget.childDirectories(in: current.url, fileManager: fileManager) {
                guard !self.skippedDirectoryNames.contains(child.lastPathComponent),
                      (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
                else { continue }
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
}
