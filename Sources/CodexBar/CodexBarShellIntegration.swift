import Foundation

/// Manages the `~/.codexbar/active-codex-home` file and optional one-time `.zshrc` hook injection.
///
/// The file contains the absolute path of the currently selected Codex account's CODEX_HOME directory.
/// A shell `precmd` hook installed in `.zshrc` re-exports `CODEX_HOME` on every prompt:
///
///     precmd_codexbar() { export CODEX_HOME=$(cat ~/.codexbar/active-codex-home 2>/dev/null); }
///     autoload -Uz add-zsh-hook && add-zsh-hook precmd precmd_codexbar
///
/// This means switching accounts in CodexBar immediately takes effect at the next shell prompt,
/// so `codex` CLI sessions are written to the correct per-account `sessions/` directory.
enum CodexBarShellIntegration {
    // MARK: - Paths

    private static var codexbarDir: URL {
        URL(fileURLWithPath: ("~/.codexbar" as NSString).expandingTildeInPath)
    }

    private static var activeCodexHomeFile: URL {
        codexbarDir.appendingPathComponent("active-codex-home")
    }

    private static var zshrcFile: URL {
        URL(fileURLWithPath: ("~/.zshrc" as NSString).expandingTildeInPath)
    }

    // MARK: - Shell hook snippet

    /// A unique sentinel so we never double-insert the hook.
    private static let hookMarker = "# CodexBar shell integration"

    private static let hookSnippet = """

# CodexBar shell integration — auto-switches CODEX_HOME when you change accounts in CodexBar
precmd_codexbar() { export CODEX_HOME=$(cat ~/.codexbar/active-codex-home 2>/dev/null); }
autoload -Uz add-zsh-hook && add-zsh-hook precmd precmd_codexbar
"""

    // MARK: - Public API

    /// Write the given CODEX_HOME path as the active account.
    /// Pass `nil` to clear (e.g. when reverting to the default ~/.codex account).
    static func setActiveCodexHome(_ path: String?) {
        let fm = FileManager.default
        let dir = codexbarDir.path
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if let path, !path.isEmpty {
            try? path.write(to: activeCodexHomeFile, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: activeCodexHomeFile)
        }
    }

    /// Append the precmd hook to ~/.zshrc if it isn't already there.
    /// Called once on first OAuth account creation — silently does nothing if already set up.
    static func installZshHookIfNeeded() {
        let zshrc = zshrcFile.path
        let fm = FileManager.default
        // If .zshrc doesn't exist yet, create it.
        if !fm.fileExists(atPath: zshrc) {
            fm.createFile(atPath: zshrc, contents: nil)
        }
        guard let existing = try? String(contentsOfFile: zshrc, encoding: .utf8) else { return }
        guard !existing.contains(hookMarker) else { return }
        try? (existing + hookSnippet).write(toFile: zshrc, atomically: true, encoding: .utf8)
    }

    /// Returns true if the zsh hook is already installed.
    static var isZshHookInstalled: Bool {
        guard let content = try? String(contentsOf: zshrcFile, encoding: .utf8) else { return false }
        return content.contains(hookMarker)
    }
}
