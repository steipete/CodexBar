import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreSecurityCLITests {
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
    func experimentalReader_prefersSecurityCLIForNonInteractiveLoad() throws {
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
                    ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(nil)
                    ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(nil)
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    let securityData = self.makeCredentialsData(
                        accessToken: "security-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600),
                        refreshToken: "security-refresh")

                    let creds = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                        .securityCLIExperimental,
                        operation: {
                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                .onlyOnUserAction,
                                operation: {
                                    try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                        try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                            .data(securityData))
                                        {
                                            try ClaudeOAuthCredentialsStore.load(
                                                environment: [:],
                                                allowKeychainPrompt: false)
                                        }
                                    }
                                })
                        })

                    #expect(creds.accessToken == "security-token")
                    #expect(creds.refreshToken == "security-refresh")
                    #expect(creds.scopes.contains("user:profile"))
                }
            }
        }
    }

    @Test
    func experimentalReader_nonInteractiveBackgroundLoad_stillExecutesSecurityCLIRead() throws {
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
                    ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(nil)
                    ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(nil)
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    let securityData = self.makeCredentialsData(
                        accessToken: "security-token-background",
                        expiresAt: Date(timeIntervalSinceNow: 3600),
                        refreshToken: "security-refresh-background")
                    final class ReadCounter: @unchecked Sendable {
                        var count = 0
                    }
                    let securityReadCalls = ReadCounter()

                    let creds = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                        .securityCLIExperimental,
                        operation: {
                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                .onlyOnUserAction,
                                operation: {
                                    try ProviderInteractionContext.$current.withValue(.background) {
                                        try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                            .dynamic { _ in
                                                securityReadCalls.count += 1
                                                return securityData
                                            }) {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: false)
                                            }
                                    }
                                })
                        })

                    #expect(creds.accessToken == "security-token-background")
                    #expect(securityReadCalls.count == 1)
                }
            }
        }
    }

    @Test
    func experimentalReader_fallsBackWhenSecurityCLIThrows() throws {
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
                    ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(nil)
                    ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(nil)
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    let fallbackData = self.makeCredentialsData(
                        accessToken: "fallback-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600),
                        refreshToken: "fallback-refresh")

                    let creds = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                        .securityCLIExperimental,
                        operation: {
                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                .onlyOnUserAction,
                                operation: {
                                    try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                        try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                            data: fallbackData,
                                            fingerprint: nil)
                                        {
                                            try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                .timedOut)
                                            {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: false)
                                            }
                                        }
                                    }
                                })
                        })

                    #expect(creds.accessToken == "fallback-token")
                }
            }
        }
    }

    @Test
    func experimentalReader_fallsBackWhenSecurityCLIOutputMalformed() throws {
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
                    ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(nil)
                    ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(nil)
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    let fallbackData = self.makeCredentialsData(
                        accessToken: "fallback-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))

                    let creds = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                        .securityCLIExperimental,
                        operation: {
                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                .onlyOnUserAction,
                                operation: {
                                    try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                        try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                            data: fallbackData,
                                            fingerprint: nil)
                                        {
                                            try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                .data(Data("not-json".utf8)))
                                            {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: false)
                                            }
                                        }
                                    }
                                })
                        })

                    #expect(creds.accessToken == "fallback-token")
                }
            }
        }
    }

    @Test
    func experimentalReader_loadFromClaudeKeychainUsesSecurityCLI() throws {
        let securityData = self.makeCredentialsData(
            accessToken: "security-direct",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            refreshToken: "security-refresh")
        let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore()
        let sentinelFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 200,
            createdAt: 199,
            persistentRefHash: "sentinel")

        let loaded = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental,
            operation: {
                try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                    .always,
                    operation: {
                        try ProviderInteractionContext.$current.withValue(.userInitiated) {
                            try ClaudeOAuthCredentialsStore.withClaudeKeychainFingerprintStoreOverrideForTesting(
                                fingerprintStore)
                            {
                                try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: nil,
                                    fingerprint: sentinelFingerprint)
                                {
                                    try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                        .data(securityData))
                                    {
                                        try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                                    }
                                }
                            }
                        }
                    })
            })

        let creds = try ClaudeOAuthCredentials.parse(data: loaded)
        #expect(creds.accessToken == "security-direct")
        #expect(creds.refreshToken == "security-refresh")
        #expect(fingerprintStore.fingerprint == nil)
    }

    @Test
    func experimentalReader_hasClaudeKeychainCredentialsWithoutPrompt_usesSecurityCLI() {
        let securityData = self.makeCredentialsData(
            accessToken: "security-available",
            expiresAt: Date(timeIntervalSinceNow: 3600))

        let hasCredentials = ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental,
            operation: {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                    .always,
                    operation: {
                        ProviderInteractionContext.$current.withValue(.userInitiated) {
                            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                .data(securityData))
                            {
                                ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt()
                            }
                        }
                    })
            })

        #expect(hasCredentials == true)
    }

    @Test
    func experimentalReader_hasClaudeKeychainCredentialsWithoutPrompt_fallsBackWhenSecurityCLIFails() {
        let fallbackData = self.makeCredentialsData(
            accessToken: "fallback-available",
            expiresAt: Date(timeIntervalSinceNow: 3600))

        let hasCredentials = ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental,
            operation: {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                    .always,
                    operation: {
                        ProviderInteractionContext.$current.withValue(.userInitiated) {
                            ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: fallbackData,
                                fingerprint: nil)
                            {
                                ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                    .nonZeroExit)
                                {
                                    ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt()
                                }
                            }
                        }
                    })
            })

        #expect(hasCredentials == true)
    }

    @Test
    func experimentalReader_ignoresPromptPolicyAndCooldownForBackgroundSilentCheck() {
        let securityData = self.makeCredentialsData(
            accessToken: "security-background",
            expiresAt: Date(timeIntervalSinceNow: 3600))

        let hasCredentials = KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthKeychainAccessGate.withShouldAllowPromptOverrideForTesting(false) {
                ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                    .securityCLIExperimental,
                    operation: {
                        ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                            .never,
                            operation: {
                                ProviderInteractionContext.$current.withValue(.background) {
                                    ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                        .data(securityData))
                                    {
                                        ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt()
                                    }
                                }
                            })
                    })
            }
        }

        #expect(hasCredentials == true)
    }

    @Test
    func experimentalReader_loadFromClaudeKeychainFallbackBlockedWhenStoredModeNever() throws {
        var threwNotFound = false
        do {
            _ = try KeychainAccessGate.withTaskOverrideForTesting(false) {
                try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                    .securityCLIExperimental,
                    operation: {
                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                            .never,
                            operation: {
                                try ProviderInteractionContext.$current.withValue(.background) {
                                    try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                        .nonZeroExit)
                                    {
                                        try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                                    }
                                }
                            })
                    })
            }
        } catch let error as ClaudeOAuthCredentialsError {
            if case .notFound = error {
                threwNotFound = true
            }
        }

        #expect(threwNotFound == true)
    }

    @Test
    func experimentalReader_securityCLIRead_pinsPreferredAccountWhenAvailable() throws {
        let securityData = self.makeCredentialsData(
            accessToken: "security-account-pinned",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        final class AccountBox: @unchecked Sendable {
            var value: String?
        }
        let pinnedAccount = AccountBox()

        let loaded = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental,
            operation: {
                try ClaudeOAuthCredentialsStore.withSecurityCLIReadAccountOverrideForTesting("new-account") {
                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                        .always,
                        operation: {
                            try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                    .dynamic { request in
                                        pinnedAccount.value = request.account
                                        return securityData
                                    }) {
                                        try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                                    }
                            }
                        })
                }
            })

        let creds = try ClaudeOAuthCredentials.parse(data: loaded)
        #expect(pinnedAccount.value == "new-account")
        #expect(creds.accessToken == "security-account-pinned")
    }

    @Test
    func experimentalReader_securityCLIRead_doesNotPinAccountInBackground() throws {
        let securityData = self.makeCredentialsData(
            accessToken: "security-account-not-pinned",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        final class AccountBox: @unchecked Sendable {
            var value: String?
        }
        let pinnedAccount = AccountBox()

        let loaded = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental,
            operation: {
                try ClaudeOAuthCredentialsStore.withSecurityCLIReadAccountOverrideForTesting("new-account") {
                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                        .always,
                        operation: {
                            try ProviderInteractionContext.$current.withValue(.background) {
                                try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                    .dynamic { request in
                                        pinnedAccount.value = request.account
                                        return securityData
                                    }) {
                                        try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                                    }
                            }
                        })
                }
            })

        let creds = try ClaudeOAuthCredentials.parse(data: loaded)
        #expect(pinnedAccount.value == nil)
        #expect(creds.accessToken == "security-account-not-pinned")
    }

    @Test
    func experimentalReader_freshnessSync_skipsSecurityCLIWhenPreflightRequiresInteraction() throws {
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
                        let securityData = self.makeCredentialsData(
                            accessToken: "security-sync",
                            expiresAt: Date(timeIntervalSinceNow: 3600))
                        final class ReadCounter: @unchecked Sendable {
                            var count = 0
                        }
                        let securityReadCalls = ReadCounter()

                        func loadWithPreflight(
                            _ outcome: KeychainAccessPreflight.Outcome) throws -> ClaudeOAuthCredentials
                        {
                            let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                                outcome
                            }
                            return try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                                preflightOverride,
                                operation: {
                                    try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                        .securityCLIExperimental)
                                    {
                                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                            try ProviderInteractionContext.$current.withValue(.background) {
                                                try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                    .dynamic { _ in
                                                        securityReadCalls.count += 1
                                                        return securityData
                                                    }) {
                                                        try ClaudeOAuthCredentialsStore.load(
                                                            environment: [:],
                                                            allowKeychainPrompt: false,
                                                            respectKeychainPromptCooldown: true)
                                                    }
                                            }
                                        }
                                    }
                                })
                        }

                        let first = try loadWithPreflight(.allowed)
                        #expect(first.accessToken == "security-sync")
                        #expect(securityReadCalls.count == 1)

                        let second = try loadWithPreflight(.interactionRequired)
                        #expect(second.accessToken == "security-sync")
                        #expect(securityReadCalls.count == 1)
                    }
                }
            }
        }
    }

    @Test
    func experimentalReader_freshnessSync_background_respectsStoredOnlyOnUserAction() throws {
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
                        let securityData = self.makeCredentialsData(
                            accessToken: "security-sync-only-on-user-action",
                            expiresAt: Date(timeIntervalSinceNow: 3600))
                        final class ReadCounter: @unchecked Sendable {
                            var count = 0
                        }
                        let securityReadCalls = ReadCounter()
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .allowed
                        }

                        func load(_ interaction: ProviderInteraction) throws -> ClaudeOAuthCredentials {
                            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                                preflightOverride,
                                operation: {
                                    try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                        .securityCLIExperimental)
                                    {
                                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                            .onlyOnUserAction)
                                        {
                                            try ProviderInteractionContext.$current.withValue(interaction) {
                                                try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                    .dynamic { _ in
                                                        securityReadCalls.count += 1
                                                        return securityData
                                                    }) {
                                                        try ClaudeOAuthCredentialsStore.load(
                                                            environment: [:],
                                                            allowKeychainPrompt: false,
                                                            respectKeychainPromptCooldown: true)
                                                    }
                                            }
                                        }
                                    }
                                })
                        }

                        let first = try load(.userInitiated)
                        #expect(first.accessToken == "security-sync-only-on-user-action")
                        #expect(securityReadCalls.count == 1)

                        let second = try load(.background)
                        #expect(second.accessToken == "security-sync-only-on-user-action")
                        #expect(securityReadCalls.count == 1)
                    }
                }
            }
        }
    }

    @Test
    func experimentalReader_syncFromClaudeKeychainWithoutPrompt_skipsFingerprintProbeAfterSecurityCLIRead() {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    defer { ClaudeOAuthCredentialsStore.invalidateCache() }

                    let securityData = self.makeCredentialsData(
                        accessToken: "security-sync-no-fingerprint-probe",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore()
                    let sentinelFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 123,
                        createdAt: 122,
                        persistentRefHash: "sentinel")

                    let synced = ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                        .securityCLIExperimental,
                        operation: {
                            ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                ProviderInteractionContext.$current.withValue(.background) {
                                    ClaudeOAuthCredentialsStore.withClaudeKeychainFingerprintStoreOverrideForTesting(
                                        fingerprintStore)
                                    {
                                        ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                            data: nil,
                                            fingerprint: sentinelFingerprint)
                                        {
                                            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                .data(securityData))
                                            {
                                                ClaudeOAuthCredentialsStore.syncFromClaudeKeychainWithoutPrompt(
                                                    now: Date())
                                            }
                                        }
                                    }
                                }
                            }
                        })

                    #expect(synced == true)
                    #expect(fingerprintStore.fingerprint == nil)
                }
            }
        }
    }

    @Test
    func experimentalReader_noPromptRepair_skipsFingerprintProbeAfterSecurityCLISuccess() throws {
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

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")
                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    let securityData = self.makeCredentialsData(
                        accessToken: "security-repair-no-fingerprint-probe",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore()
                    let sentinelFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 456,
                        createdAt: 455,
                        persistentRefHash: "sentinel")

                    let record = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                        .securityCLIExperimental,
                        operation: {
                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                try ProviderInteractionContext.$current.withValue(.background) {
                                    try ClaudeOAuthCredentialsStore
                                        .withClaudeKeychainFingerprintStoreOverrideForTesting(
                                            fingerprintStore)
                                        {
                                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: nil,
                                                fingerprint: sentinelFingerprint)
                                            {
                                                try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                    .data(securityData))
                                                {
                                                    try ClaudeOAuthCredentialsStore.loadRecord(
                                                        environment: [:],
                                                        allowKeychainPrompt: false,
                                                        respectKeychainPromptCooldown: true)
                                                }
                                            }
                                        }
                                }
                            }
                        })

                    #expect(record.credentials.accessToken == "security-repair-no-fingerprint-probe")
                    #expect(record.source == .claudeKeychain)
                    #expect(fingerprintStore.fingerprint == nil)
                }
            }
        }
    }

    @Test
    func experimentalReader_loadWithPrompt_skipsFingerprintProbeAfterSecurityCLISuccess() throws {
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

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")
                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    let securityData = self.makeCredentialsData(
                        accessToken: "security-load-with-prompt",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore()
                    let sentinelFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 321,
                        createdAt: 320,
                        persistentRefHash: "sentinel")

                    let creds = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                        .securityCLIExperimental,
                        operation: {
                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                    try ClaudeOAuthCredentialsStore
                                        .withClaudeKeychainFingerprintStoreOverrideForTesting(
                                            fingerprintStore)
                                        {
                                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: nil,
                                                fingerprint: sentinelFingerprint)
                                            {
                                                try ClaudeOAuthCredentialsStore
                                                    .withSecurityCLIReadOverrideForTesting(
                                                        .data(securityData))
                                                    {
                                                        try ClaudeOAuthCredentialsStore.load(
                                                            environment: [:],
                                                            allowKeychainPrompt: true,
                                                            respectKeychainPromptCooldown: false)
                                                    }
                                            }
                                        }
                                }
                            }
                        })

                    #expect(creds.accessToken == "security-load-with-prompt")
                    #expect(fingerprintStore.fingerprint == nil)
                }
            }
        }
    }

    @Test
    func experimentalReader_loadWithPrompt_doesNotReadWhenGlobalKeychainDisabled() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(true) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

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
                    let securityData = self.makeCredentialsData(
                        accessToken: "security-should-not-read",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    var threwNotFound = false
                    final class ReadCounter: @unchecked Sendable {
                        var count = 0
                    }
                    let securityReadCalls = ReadCounter()

                    do {
                        _ = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                            .securityCLIExperimental,
                            operation: {
                                try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                    try ProviderInteractionContext.$current.withValue(.userInitiated) {
                                        try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                            .dynamic { _ in
                                                securityReadCalls.count += 1
                                                return securityData
                                            }) {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: true,
                                                    respectKeychainPromptCooldown: false)
                                            }
                                    }
                                }
                            })
                    } catch let error as ClaudeOAuthCredentialsError {
                        if case .notFound = error {
                            threwNotFound = true
                        } else {
                            throw error
                        }
                    }

                    #expect(threwNotFound == true)
                    #expect(securityReadCalls.count < 1)
                }
            }
        }
    }
}
