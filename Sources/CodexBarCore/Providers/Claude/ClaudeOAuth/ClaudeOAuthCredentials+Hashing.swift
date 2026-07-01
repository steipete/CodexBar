import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

extension ClaudeOAuthCredentialsStore {
    static func sha256Prefix(_ data: Data) -> String? {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
        #else
        _ = data
        return nil
        #endif
    }

    /// Suffix that Claude Code appends to the Keychain service name for a custom
    /// `CLAUDE_CONFIG_DIR`. Claude Code derives it from the lowercased hex SHA-256
    /// of the config directory's absolute path, truncated to the first 8 characters.
    ///
    /// Example: `/Users/alice/.claude-work` → `da6d47a8` →
    /// Keychain service `"Claude Code-credentials-da6d47a8"`.
    static func claudeConfigDirHash8(_ path: String) -> String? {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
        #else
        _ = path
        return nil
        #endif
    }
}
