import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthRefreshChainOwnershipTests {
    private func makeCredentials(
        accessToken: String = "cached-access-token",
        expiresAt: Date = Date(timeIntervalSinceNow: 3600)) -> ClaudeOAuthCredentials
    {
        ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: "cached-refresh-token",
            expiresAt: expiresAt,
            scopes: ["user:profile"],
            rateLimitTier: nil)
    }

    private func credentialsData(
        accessToken: String,
        expiresAt: Date = Date(timeIntervalSinceNow: 3600)) -> Data
    {
        let expiresAtMilliseconds = Int(expiresAt.timeIntervalSince1970 * 1000)
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "refreshToken": "cached-refresh-token",
            "expiresAt": \(expiresAtMilliseconds),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)
    }

    private func makeProfile(accountUuid: String?, credentialsData: Data? = nil) throws
        -> (directory: URL, environment: [String: String])
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let accountUuid {
            let config = Data("""
            {
              "oauthAccount": {
                "accountUuid": "\(accountUuid)"
              }
            }
            """.utf8)
            try config.write(to: directory.appendingPathComponent(".claude.json"))
        }
        if let credentialsData {
            try credentialsData.write(to: directory.appendingPathComponent(".credentials.json"))
        }
        return (directory, [ClaudeConfigPaths.configDirectoryEnvironmentKey: directory.path])
    }

    private func makeProfileWithRawConfig(_ rawConfig: Data) throws
        -> (directory: URL, environment: [String: String])
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rawConfig.write(to: directory.appendingPathComponent(".claude.json"))
        return (directory, [ClaudeConfigPaths.configDirectoryEnvironmentKey: directory.path])
    }

    @Test
    func `unavailable probe with logged in config delegates expired codexbar mirror`() async throws {
        let profile = try self.makeProfile(accountUuid: "logged-in-profile")
        defer { try? FileManager.default.removeItem(at: profile.directory) }

        let service = "com.steipete.codexbar.refresh-chain-ownership.\(UUID().uuidString)"
        let pendingStore = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await KeychainAccessGate.withTaskOverrideForTesting(true) {
                try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        try await ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(
                            pendingStore)
                        {
                            try await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(nil)) {
                                try await ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
                                    try await ClaudeOAuthCredentialsStore
                                        .withIsolatedCredentialsFileTrackingForTesting {
                                            try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                                                let profileIdentifier = ClaudeOAuthCredentialsStore
                                                    .credentialsProfileIdentifier(environment: profile.environment)
                                                let cacheKey = ClaudeOAuthCredentialsStore.cacheKeyForTesting(
                                                    profileIdentifier: profileIdentifier)
                                                let expiredData = self.credentialsData(
                                                    accessToken: "expired-cached-access-token",
                                                    expiresAt: Date(timeIntervalSinceNow: -3600))
                                                KeychainCacheStore.store(
                                                    key: cacheKey,
                                                    entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                                        data: expiredData,
                                                        storedAt: Date(),
                                                        owner: .codexbar,
                                                        profileIdentifier: profileIdentifier))

                                                let record = try ClaudeOAuthCredentialsStore.loadRecord(
                                                    environment: profile.environment,
                                                    allowKeychainPrompt: false,
                                                    respectKeychainPromptCooldown: true,
                                                    allowClaudeKeychainRepairWithoutPrompt: false)
                                                #expect(record.owner == .claudeCLI)

                                                do {
                                                    _ = try await ClaudeOAuthCredentialsStore
                                                        .loadRecordWithAutoRefresh(
                                                            environment: profile.environment,
                                                            allowKeychainPrompt: false,
                                                            respectKeychainPromptCooldown: true,
                                                            allowClaudeKeychainRepairWithoutPrompt: false)
                                                    Issue.record("Expected Claude CLI delegated refresh")
                                                } catch let error as ClaudeOAuthCredentialsError {
                                                    guard case .refreshDelegatedToClaudeCLI = error else {
                                                        Issue.record(
                                                            "Expected .refreshDelegatedToClaudeCLI, got \(error)")
                                                        return
                                                    }
                                                } catch {
                                                    Issue.record("Expected ClaudeOAuthCredentialsError, got \(error)")
                                                }
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `consent off keeps a keychain only signed in profile CLI owned`() throws {
        let profile = try self.makeProfile(accountUuid: "keychain-only-profile")
        defer { try? FileManager.default.removeItem(at: profile.directory) }
        let keychain = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore()

        let owner = KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(false) {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(keychain) {
                        #expect(!ClaudeOAuthCredentialsStore.keychainAccessAllowed)
                        #expect(ClaudeAccountProfile.configOwnershipEvidence(environment: profile.environment)
                            == .signedIn(accountUuid: "keychain-only-profile"))
                        #expect(ClaudeOAuthCredentialsStore.claudeKeychainCredentialMatchForTesting(
                            credentials: self.makeCredentials()) == .unavailable)
                        return ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                            .codexbar,
                            credentials: self.makeCredentials(),
                            environment: profile.environment)
                    }
                }
            }
        }

        #expect(owner == .claudeCLI)
    }

    @Test
    func `consent on restores verified keychain absence for a signed in profile`() throws {
        let profile = try self.makeProfile(accountUuid: "consented-profile")
        defer { try? FileManager.default.removeItem(at: profile.directory) }
        let keychain = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore()

        let owner = KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(true) {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(keychain) {
                        #expect(ClaudeOAuthCredentialsStore.keychainAccessAllowed)
                        #expect(ClaudeAccountProfile.configOwnershipEvidence(environment: profile.environment)
                            == .signedIn(accountUuid: "consented-profile"))
                        #expect(ClaudeOAuthCredentialsStore.claudeKeychainCredentialMatchForTesting(
                            credentials: self.makeCredentials()) == .absent)
                        return ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                            .codexbar,
                            credentials: self.makeCredentials(),
                            environment: profile.environment)
                    }
                }
            }
        }

        #expect(owner == .codexbar)
    }

    @Test
    func `unavailable probe without logged in config keeps codexbar ownership`() throws {
        let profile = try self.makeProfile(accountUuid: nil)
        defer { try? FileManager.default.removeItem(at: profile.directory) }

        let owner = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(nil)) {
                ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                    .codexbar,
                    credentials: self.makeCredentials(),
                    environment: profile.environment)
            }
        }

        #expect(owner == .codexbar)
    }

    @Test
    func `absent keychain item keeps codexbar ownership`() throws {
        let profile = try self.makeProfile(accountUuid: nil)
        defer { try? FileManager.default.removeItem(at: profile.directory) }
        let keychain = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore()

        let owner = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(keychain) {
                ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                    .codexbar,
                    credentials: self.makeCredentials(),
                    environment: profile.environment)
            }
        }

        #expect(owner == .codexbar)
    }

    @Test
    func `mismatched keychain item delegates codexbar ownership to CLI`() throws {
        let profile = try self.makeProfile(accountUuid: nil)
        defer { try? FileManager.default.removeItem(at: profile.directory) }
        let keychainData = self.credentialsData(accessToken: "different-keychain-access-token")
        let keychainFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 2,
            createdAt: 1,
            persistentRefHash: "different-keychain-item")

        let owner = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                data: keychainData,
                fingerprint: keychainFingerprint)
            {
                ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                    .codexbar,
                    credentials: self.makeCredentials(),
                    environment: profile.environment)
            }
        }

        #expect(owner == .claudeCLI)
    }

    @Test
    func `credentials file keeps codexbar mirror CLI owned`() throws {
        let profile = try self.makeProfile(
            accountUuid: nil,
            credentialsData: self.credentialsData(accessToken: "credentials-file-access-token"))
        defer { try? FileManager.default.removeItem(at: profile.directory) }

        let owner = ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
            ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                .codexbar,
                credentials: self.makeCredentials(),
                environment: profile.environment)
        }

        #expect(owner == .claudeCLI)
    }

    @Test
    func `never prompt mode falls back to logged in config`() throws {
        let profile = try self.makeProfile(accountUuid: "never-mode-profile")
        defer { try? FileManager.default.removeItem(at: profile.directory) }

        let owner = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
            ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                .codexbar,
                credentials: self.makeCredentials(),
                environment: profile.environment)
        }

        #expect(owner == .claudeCLI)
    }

    @Test
    func `malformed config keeps the mirror CLI owned`() throws {
        let profile = try self.makeProfileWithRawConfig(Data("not json {".utf8))
        defer { try? FileManager.default.removeItem(at: profile.directory) }

        let owner = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(nil)) {
                ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                    .codexbar,
                    credentials: self.makeCredentials(),
                    environment: profile.environment)
            }
        }

        #expect(owner == .claudeCLI)
    }

    @Test
    func `oauth account without identity keeps the mirror CLI owned`() throws {
        let profile = try self.makeProfileWithRawConfig(Data("""
        {
          "oauthAccount": {
            "accountUuid": "   "
          }
        }
        """.utf8))
        defer { try? FileManager.default.removeItem(at: profile.directory) }

        let owner = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(nil)) {
                ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                    .codexbar,
                    credentials: self.makeCredentials(),
                    environment: profile.environment)
            }
        }

        #expect(owner == .claudeCLI)
    }

    @Test
    func `cleanly signed out config releases the mirror to codexbar`() throws {
        let profile = try self.makeProfileWithRawConfig(Data("""
        {
          "installMethod": "brew"
        }
        """.utf8))
        defer { try? FileManager.default.removeItem(at: profile.directory) }

        let owner = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(nil)) {
                ClaudeOAuthCredentialsStore.resolvedCacheOwnerForTesting(
                    .codexbar,
                    credentials: self.makeCredentials(),
                    environment: profile.environment)
            }
        }

        #expect(owner == .codexbar)
    }
}
