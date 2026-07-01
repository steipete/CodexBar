import Foundation
import Testing
@testable import CodexBarCore

/// Tests for reading Claude OAuth credentials for a specific `CLAUDE_CONFIG_DIR`, so a single
/// CodexBar process can report usage for multiple Claude subscription accounts.
///
/// Claude Code stores each config directory's OAuth token under a distinct Keychain service:
/// `"Claude Code-credentials"` for the default `~/.claude`, and
/// `"Claude Code-credentials-<hash>"` for a custom `CLAUDE_CONFIG_DIR`, where `<hash>` is the
/// first 8 hex chars of the directory path's SHA-256.
@Suite(.serialized)
struct ClaudeOAuthConfigDirAccountTests {
    private func makeCredentialsData(accessToken: String, expiresAt: Date, refreshToken: String? = nil) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let refreshField: String = {
            guard let refreshToken else { return "" }
            return ",\n            \"refreshToken\": \"\(refreshToken)\""
        }()
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]\(refreshField)
          }
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Keychain service derivation

    @Test
    func `default config dir uses the suffix-less keychain service`() {
        #expect(
            ClaudeOAuthCredentialsStore.claudeKeychainServiceForTesting(configDir: nil)
                == "Claude Code-credentials")

        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        #expect(
            ClaudeOAuthCredentialsStore.claudeKeychainServiceForTesting(configDir: home)
                == "Claude Code-credentials")
    }

    @Test
    func `custom config dir appends the sha256 hash suffix`() {
        // Verified against a real Keychain entry: sha256("/Users/lawyzheng/.claude-lawyzheng")[0..<8] == da6d47a8
        #expect(
            ClaudeOAuthCredentialsStore.claudeKeychainServiceForTesting(
                configDir: "/Users/lawyzheng/.claude-lawyzheng")
                == "Claude Code-credentials-da6d47a8")
    }

    @Test
    func `hash matches sha256 first eight hex chars`() {
        let path = "/tmp/example-claude-config"
        let expected = ClaudeOAuthCredentialsStore.claudeConfigDirHash8(path)
        #expect(expected?.count == 8)
        #expect(
            ClaudeOAuthCredentialsStore.claudeKeychainServiceForTesting(configDir: path)
                == "Claude Code-credentials-\(expected ?? "")")
    }

    // MARK: - Credentials file path follows the config dir

    @Test
    func `credentials file is read from the config dir`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore.invalidateCache()
                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                }

                // Write a credentials file inside a fake CLAUDE_CONFIG_DIR.
                let configDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                let credentialsURL = configDir.appendingPathComponent(".credentials.json")
                try self.makeCredentialsData(
                    accessToken: "config-dir-token",
                    expiresAt: Date(timeIntervalSinceNow: 3600),
                    refreshToken: "config-dir-refresh").write(to: credentialsURL)

                let creds = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                    .securityCLIExperimental,
                    operation: {
                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                            .onlyOnUserAction,
                            operation: {
                                try ClaudeOAuthCredentialsStore.load(
                                    environment: ["CLAUDE_CONFIG_DIR": configDir.path],
                                    allowKeychainPrompt: false)
                            })
                    })

                #expect(creds.accessToken == "config-dir-token")
                #expect(creds.refreshToken == "config-dir-refresh")
            }
        }
    }

    // MARK: - Accounts do not cross-read via the in-memory cache

    @Test
    func `memory cache does not leak between config dirs`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore.invalidateCache()
                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                }

                func makeConfigDir(token: String) throws -> URL {
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try self.makeCredentialsData(
                        accessToken: token,
                        expiresAt: Date(timeIntervalSinceNow: 3600),
                        refreshToken: "\(token)-refresh")
                        .write(to: dir.appendingPathComponent(".credentials.json"))
                    return dir
                }

                let dirA = try makeConfigDir(token: "account-a-token")
                let dirB = try makeConfigDir(token: "account-b-token")

                try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                    .securityCLIExperimental,
                    operation: {
                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                            .onlyOnUserAction,
                            operation: {
                                // Read account A first (this may populate the in-memory cache).
                                let a = try ClaudeOAuthCredentialsStore.load(
                                    environment: ["CLAUDE_CONFIG_DIR": dirA.path],
                                    allowKeychainPrompt: false)
                                #expect(a.accessToken == "account-a-token")

                                // Reading account B must not return account A's cached token.
                                let b = try ClaudeOAuthCredentialsStore.load(
                                    environment: ["CLAUDE_CONFIG_DIR": dirB.path],
                                    allowKeychainPrompt: false)
                                #expect(b.accessToken == "account-b-token")
                            })
                    })
            }
        }
    }
}
