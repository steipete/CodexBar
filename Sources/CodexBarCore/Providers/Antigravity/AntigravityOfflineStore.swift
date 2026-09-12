import Foundation

/// Offline Antigravity CLI store (tokscale lesson): counts local SQLite conversations
/// at `~/.gemini/antigravity-cli/conversations/*.db` without requiring a running
/// language server or OAuth. Used as a last-resort fallback when live quota
/// probes and OAuth both fail.
public enum AntigravityOfflineStore {
    /// Resolve the base Gemini home directory. Mirrors tokscale's `GEMINI_CLI_HOME`
    /// override: if the env var is set and non-empty, use it; otherwise `~/.gemini`.
    public static func geminiHomeDirectory(home: URL, env: [String: String]) -> URL {
        if let override = env["GEMINI_CLI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // Provider-specific by design: CLI home path is a fixed external contract.
        return home.appendingPathComponent(".gemini", isDirectory: true)
    }

    public static func conversationsDirectory(home: URL, env: [String: String] = [:]) -> URL {
        self.geminiHomeDirectory(home: home, env: env)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    public static func appDataDirectory(home: URL, env: [String: String] = [:]) -> URL {
        self.geminiHomeDirectory(home: home, env: env)
            .appendingPathComponent("antigravity", isDirectory: true)
    }

    /// Tokscale cache alternative: `~/.config/tokscale/antigravity-cache/sessions`
    public static func tokscaleCacheDirectory(home: URL) -> URL {
        home.appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("tokscale", isDirectory: true)
            .appendingPathComponent("antigravity-cache", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Count offline conversations (`.db` files). Cheap, no SQLite open.
    public static func countConversations(
        home: URL,
        env: [String: String] = [:],
        fileManager: FileManager = .default) -> Int
    {
        let primary = self.conversationsDirectory(home: home, env: env)
        let appData = self.appDataDirectory(home: home, env: env)
        let appDataConversations = appData.appendingPathComponent("conversations", isDirectory: true)
        let primaryCount = self.countDBFiles(in: primary, fileManager: fileManager)
        let appDataCount = self.countDBFiles(in: appData, fileManager: fileManager)
        let appDataConvCount = self.countDBFiles(in: appDataConversations, fileManager: fileManager)
        let totalDB = primaryCount + appDataCount + appDataConvCount
        if totalDB > 0 { return totalDB }
        // Fallback to tokscale JSONL cache (also counts as offline availability)
        let cache = self.tokscaleCacheDirectory(home: home)
        return self.countJSONLFiles(in: cache, fileManager: fileManager)
    }

    public static func hasOfflineData(
        home: URL,
        env: [String: String] = [:],
        fileManager: FileManager = .default) -> Bool
    {
        self.countConversations(home: home, env: env, fileManager: fileManager) > 0
    }

    private static func countDBFiles(in directory: URL, fileManager: FileManager) -> Int {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        return contents.count(where: { $0.pathExtension.lowercased() == "db" })
    }

    private static func countJSONLFiles(in directory: URL, fileManager: FileManager) -> Int {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        return contents.count(where: { $0.pathExtension.lowercased() == "jsonl" })
    }
}
