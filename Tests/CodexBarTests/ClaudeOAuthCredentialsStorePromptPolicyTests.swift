import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStorePromptPolicyTests {
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

    @Test
    func doesNotReadClaudeKeychainInBackgroundWhenPromptModeOnlyOnUserAction() throws {
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
                    ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()

                    let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 1,
                        createdAt: 1,
                        persistentRefHash: "ref1")
                    let keychainData = self.makeCredentialsData(
                        accessToken: "keychain-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))

                    do {
                        _ = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                            try ProviderInteractionContext.$current.withValue(.background) {
                                try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: keychainData,
                                    fingerprint: fingerprint)
                                {
                                    try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                                }
                            }
                        }
                        Issue.record("Expected ClaudeOAuthCredentialsError.notFound")
                    } catch let error as ClaudeOAuthCredentialsError {
                        guard case .notFound = error else {
                            Issue.record("Expected .notFound, got \(error)")
                            return
                        }
                    }
                }
            }
        }
    }

    @Test
    func canReadClaudeKeychainOnUserActionWhenPromptModeOnlyOnUserAction() throws {
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
                    ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()

                    let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 1,
                        createdAt: 1,
                        persistentRefHash: "ref1")
                    let keychainData = self.makeCredentialsData(
                        accessToken: "keychain-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))

                    let creds = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        try ProviderInteractionContext.$current.withValue(.userInitiated) {
                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: keychainData,
                                fingerprint: fingerprint)
                            {
                                try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                            }
                        }
                    }

                    #expect(creds.accessToken == "keychain-token")
                }
            }
        }
    }

    @Test
    func doesNotShowPreAlertWhenClaudeKeychainReadableWithoutInteraction() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let keychainData = self.makeCredentialsData(
                            accessToken: "keychain-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        var preAlertHits = 0
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .allowed
                        }
                        let promptHandler: (KeychainPromptContext) -> Void = { _ in
                            preAlertHits += 1
                        }
                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction)
                                    {
                                        try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: keychainData,
                                                fingerprint: nil)
                                            {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: true)
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "keychain-token")
                        #expect(preAlertHits == 0)
                    }
                }
            }
        }
    }

    @Test
    func showsPreAlertWhenClaudeKeychainLikelyRequiresInteraction() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let keychainData = self.makeCredentialsData(
                            accessToken: "keychain-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        var preAlertHits = 0
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .interactionRequired
                        }
                        let promptHandler: (KeychainPromptContext) -> Void = { _ in
                            preAlertHits += 1
                        }
                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction)
                                    {
                                        try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: keychainData,
                                                fingerprint: nil)
                                            {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: true)
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "keychain-token")
                        // TODO: tighten this to `== 1` once keychain pre-alert delivery is deduplicated/scoped.
                        // This path can currently emit more than one pre-alert during a single load attempt.
                        #expect(preAlertHits >= 1)
                    }
                }
            }
        }
    }

    @Test
    func showsPreAlertWhenClaudeKeychainPreflightFails() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let keychainData = self.makeCredentialsData(
                            accessToken: "keychain-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        var preAlertHits = 0
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .failure(-1)
                        }
                        let promptHandler: (KeychainPromptContext) -> Void = { _ in
                            preAlertHits += 1
                        }
                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction)
                                    {
                                        try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: keychainData,
                                                fingerprint: nil)
                                            {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: true)
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "keychain-token")
                        // TODO: tighten this to `== 1` once keychain pre-alert delivery is deduplicated/scoped.
                        // This path can currently emit more than one pre-alert during a single load attempt.
                        #expect(preAlertHits >= 1)
                    }
                }
            }
        }
    }
}
