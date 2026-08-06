import CodexBarCore
import Foundation

extension SettingsStore {
    func costSummaryShowsInlineDashboard(for provider: UsageProvider) -> Bool {
        // Provider-specific by design: DeepSeek's API exposes a balance card but no token-cost submenu data.
        if provider == .deepseek {
            return self.costUsageEnabled
        }
        return self.isCostUsageEffectivelyEnabled(for: provider) &&
            self.costSummaryDisplayStyle.showsInlineSummary
    }

    func costSummaryShowsSubmenu(for provider: UsageProvider) -> Bool {
        self.isCostUsageEffectivelyEnabled(for: provider) &&
            self.costSummaryDisplayStyle.showsCostSubmenu
    }

    func applyTokenCostDefaultIfNeeded() {
        // Tests cover detection directly; skip filesystem-driven auto-enablement to keep startup deterministic.
        guard !Self.isRunningTests else { return }
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
        homeDirectory: URL? = nil,
        workingDirectory: URL? = nil) -> Bool
    {
        // Provider-specific by design: only Codex and Claude have local JSONL scanners that can auto-enable token cost.
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

        if hasAnyJsonl(in: codexRoot) {
            return true
        }
        if let archivedCodexRoot, hasAnyJsonl(in: archivedCodexRoot) {
            return true
        }

        let claudeRoots: [URL] = {
            if let configuredRoot = env[ClaudeConfigPaths.configDirectoryEnvironmentKey],
               !configuredRoot.isEmpty
            {
                return [ClaudeConfigPaths.configRoot(
                    environment: env,
                    workingDirectory: workingDirectory)
                    .appendingPathComponent("projects", isDirectory: true)]
            }

            var pathEnvironment = env
            if pathEnvironment["HOME"]?.isEmpty ?? true {
                pathEnvironment["HOME"] = home.path
            }
            let ownerHome = ClaudeConfigPaths.homeDirectory(
                environment: pathEnvironment,
                workingDirectory: workingDirectory)
            let configRoot = ClaudeConfigPaths.configRoot(
                environment: pathEnvironment,
                workingDirectory: workingDirectory)
            return [
                ownerHome.appendingPathComponent(".config/claude/projects", isDirectory: true),
                configRoot.appendingPathComponent("projects", isDirectory: true),
            ] + ClaudeDesktopProjectsLocator.roots(homeDirectory: ownerHome, fileManager: fileManager)
        }()

        if claudeRoots.contains(where: hasAnyJsonl(in:)) {
            return true
        }

        // Provider-specific by design: Grok local cost auto-enablement scans ~/.grok/sessions.
        let grokRoot: URL = {
            let raw = env["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw, !raw.isEmpty {
                return URL(fileURLWithPath: raw).appendingPathComponent("sessions", isDirectory: true)
            }
            return home
                .appendingPathComponent(".grok", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }()
        return hasAnyJsonl(in: grokRoot)
    }
}
