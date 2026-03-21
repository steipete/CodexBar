import Foundation

/// When Codex must not fall back to `~/.codex`, subprocess env uses this non-existent `CODEX_HOME`.
public enum CodexDefaultHomeIsolation {
    public static func sentinelCodexHomePath(fileManager: FileManager = .default) -> String {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("isolated-no-default-codex-home", isDirectory: true)
            .path
    }
}
