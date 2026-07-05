import CodexBarCore
import Foundation

extension SettingsStore {
    func costSummaryShowsInlineDashboard(for provider: UsageProvider) -> Bool {
        self.isCostUsageEffectivelyEnabled(for: provider) &&
            self.costSummaryDisplayStyle.showsInlineSummary
    }

    func costSummaryShowsSubmenu(for provider: UsageProvider) -> Bool {
        self.isCostUsageEffectivelyEnabled(for: provider) &&
            self.costSummaryDisplayStyle.showsCostSubmenu
    }

    func applyTokenCostDefaultIfNeeded() {
        // Settings are persisted in UserDefaults.standard.
        guard UserDefaults.standard.object(forKey: "tokenCostUsageEnabled") == nil else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let hasSources = await Task.detached(priority: .utility) {
                Self.hasAnyTokenCostUsageSources()
            }.value
            guard hasSources else { return }
            guard UserDefaults.standard.object(forKey: "tokenCostUsageEnabled") == nil else { return }
            self.costUsageEnabled = true
        }
    }

    nonisolated static func hasAnyTokenCostUsageSources(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) -> Bool
    {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser

        func hasAnyJsonl(in root: URL) -> Bool {
            guard fileManager.fileExists(atPath: root.path) else { return false }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return false }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                return true
            }
            return false
        }

        let codexRoot: URL = {
            let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw, !raw.isEmpty {
                return URL(fileURLWithPath: raw).appendingPathComponent("sessions", isDirectory: true)
            }
            return home
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }()

        let archivedCodexRoot: URL? = {
            guard codexRoot.lastPathComponent == "sessions" else { return nil }
            return codexRoot
                .deletingLastPathComponent()
                .appendingPathComponent("archived_sessions", isDirectory: true)
        }()

        if hasAnyJsonl(in: codexRoot) { return true }
        if let archivedCodexRoot, hasAnyJsonl(in: archivedCodexRoot) { return true }

        let claudeRoots: [URL] = {
            if let env = env["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !env.isEmpty
            {
                return env.split(separator: ",").map { part in
                    let raw = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = URL(fileURLWithPath: raw)
                    if url.lastPathComponent == "projects" {
                        return url
                    }
                    return url.appendingPathComponent("projects", isDirectory: true)
                }
            }

            return [
                home.appendingPathComponent(".config/claude/projects", isDirectory: true),
                home.appendingPathComponent(".claude/projects", isDirectory: true),
            ] + self.claudeDesktopLocalAgentProjectsRoots(homeDirectory: home, fileManager: fileManager)
        }()

        return claudeRoots.contains(where: hasAnyJsonl(in:))
    }

    private nonisolated static func claudeDesktopLocalAgentProjectsRoots(
        homeDirectory: URL,
        fileManager: FileManager) -> [URL]
    {
        let sessionsRoot = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        var roots: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(sessionsRoot, 0)]
        var visited: Set<String> = [sessionsRoot.standardizedFileURL.path]
        var nextIndex = 0
        // Covers observed Desktop local-agent layouts through workspace/session/agent/local_agent
        // without descending into arbitrary checked-out workspaces.
        let maxDepth = 4

        while nextIndex < queue.count {
            let current = queue[nextIndex]
            nextIndex += 1
            if let projects = self.claudeProjectsRootUnderDesktopLocalAgentBase(
                current.url,
                fileManager: fileManager)
            {
                roots.append(projects)
            }

            guard current.depth < maxDepth else { continue }
            for child in self.claudeDesktopLocalAgentChildDirectories(at: current.url, fileManager: fileManager) {
                let standardized = child.standardizedFileURL
                guard visited.insert(standardized.path).inserted else { continue }
                queue.append((standardized, current.depth + 1))
            }
        }
        return roots
    }

    private nonisolated static func claudeProjectsRootUnderDesktopLocalAgentBase(
        _ base: URL,
        fileManager: FileManager) -> URL?
    {
        let projects = base
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projects.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return projects
    }

    private nonisolated static func claudeDesktopLocalAgentChildDirectories(
        at url: URL,
        fileManager: FileManager) -> [URL]
    {
        let skippedDirectoryNames = Set([
            ".build",
            ".git",
            "build",
            "DerivedData",
            "node_modules",
            "outputs",
            "target",
        ])
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            return []
        }

        return children.compactMap { child in
            guard !skippedDirectoryNames.contains(child.lastPathComponent) else { return nil }
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
