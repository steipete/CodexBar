import CodexBarCore
import Foundation

extension UsageStore {
    func tokenSnapshot(for provider: UsageProvider) -> CCUsageTokenSnapshot? {
        self.tokenSnapshots[provider]
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider)
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }

    nonisolated static func legacyCCUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("ccusage-min", isDirectory: true)
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        switch provider {
        case .codex:
            let root = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { raw -> String? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return "\(trimmed)/sessions"
            } ?? "\(home)/.codex/sessions"
            return "No Codex sessions found in \(root)."
        case .claude:
            return "No Claude usage logs found in ~/.config/claude/projects or ~/.claude/projects."
        case .gemini:
            return "Gemini cost summary is not supported."
        case .antigravity:
            return "Antigravity cost summary is not supported."
        case .cursor:
            return "Cursor cost summary is not supported."
        }
    }
}
