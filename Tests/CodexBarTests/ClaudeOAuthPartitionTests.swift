#if os(macOS)
import Foundation
import Security
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct ClaudeOAuthPartitionTests {
    private let payload = Data("synthetic-claude-credential".utf8)

    private func withFixture(
        reads: LockIsolated<Int>,
        readStatus: OSStatus = errSecSuccess,
        interactive: Bool = false,
        account: String? = "synthetic-account",
        operation: () async throws -> Void) async rethrows
    {
        try await BrowserCookieAccessGate.withIsolatedStateForTesting {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                try await ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(true) {
                    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                        try await ClaudeOAuthKeychainReadStrategyPreference
                            .withTaskOverrideForTesting(.securityFramework) {
                                try await ClaudeOAuthKeychainAccessGate
                                    .withDeniedUntilStoreOverrideForTesting(.init()) {
                                        let payload = self.payload
                                        try await ClaudeOAuthKeychainQueryTiming.$copyMatchingOverride.withValue(
                                            { query in
                                                if query[kSecReturnData as String] as? Bool == true {
                                                    #expect((query[kSecUseAuthenticationContext as String] == nil) ==
                                                        interactive)
                                                    reads.setValue(reads.value + 1)
                                                    return (readStatus, payload as NSData, 0)
                                                }
                                                var row: [String: Any] = [
                                                    kSecValuePersistentRef as String: Data("synthetic-ref".utf8),
                                                ]
                                                if let account { row[kSecAttrAccount as String] = account }
                                                let result: AnyObject = query[kSecMatchLimit as String] as? String
                                                    == kSecMatchLimitAll as String ? [row] as NSArray :
                                                    row as NSDictionary
                                                return (errSecSuccess, result, 0)
                                            },
                                            operation: operation)
                                    }
                            }
                    }
                }
            }
        }
    }

    @Test(arguments: [
        KeychainAccessPreflight.Outcome.temporarilyUnavailable, .failure(-1), .notFound,
    ])
    func `inconclusive inspection cannot spend a manual prompt`(_ outcome: KeychainAccessPreflight.Outcome) async {
        let reads = LockIsolated(0)
        await self.withFixture(reads: reads) {
            await KeychainAccessPreflight.withPartitionCheckOverrideForTesting { _, _, _ in outcome } operation: {
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    BrowserCookieAccessGate.withExplicitRetry {
                        #expect(throws: (any Error).self) {
                            try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                        }
                        #expect(reads.value == 0)
                        #expect(BrowserCookieAccessGate.claimCredentialRead(service: "synthetic-other"))
                    }
                }
            }
        }
    }

    @Test
    func `unidentified candidate cannot use a different items preflight`() async {
        let reads = LockIsolated(0)
        await self.withFixture(reads: reads, account: nil) {
            await KeychainAccessPreflight.withPartitionCheckOverrideForTesting { _, _, _ in
                Issue.record("An accountless candidate cannot be matched to a service/account preflight")
                return .allowed
            } operation: {
                await ProviderInteractionContext.$current.withValue(.background) {
                    #expect(ClaudeOAuthCredentialsStore.readRawClaudeKeychainPayloadViaSecurityFrameworkWithoutPrompt()
                        == nil)
                }
                #expect(reads.value == 0)
            }
        }
    }

    @Test
    func `partition rotation stops background and settings payload reads`() async throws {
        let reads = LockIsolated(0)
        let partitions = try LockIsolated([KeychainAccessPreflightPartitionTests.description(["teamid:OURS"])])
        try await self.withFixture(reads: reads) {
            try await KeychainAccessPreflight.withPartitionCheckOverrideForTesting { service, account, required in
                #expect(service == "Claude Code-credentials")
                #expect(account == "synthetic-account")
                #expect(required)
                return KeychainAccessPreflight.evaluatePartitionList(
                    descriptions: partitions.value, callerTeam: "OURS") == .allowed ? .allowed : .interactionRequired
            } operation: {
                await ProviderInteractionContext.$current.withValue(.background) {
                    #expect(ClaudeOAuthCredentialsStore.readRawClaudeKeychainPayloadViaSecurityFrameworkWithoutPrompt()
                        == self.payload)
                }
                #expect(reads.value == 1)
                try partitions.setValue([KeychainAccessPreflightPartitionTests.description(["apple-tool:"])])
                await ProviderInteractionContext.$current.withValue(.background) {
                    #expect(ClaudeOAuthCredentialsStore.readRawClaudeKeychainPayloadViaSecurityFrameworkWithoutPrompt()
                        == nil)
                }
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    BrowserCookieKeychainAccessGate.withUserInteractionDisallowed {
                        #expect(ClaudeOAuthCredentialsStore
                            .readRawClaudeKeychainPayloadViaSecurityFrameworkWithoutPrompt() == nil)
                    }
                }
                #expect(reads.value == 1)
            }
        }
    }

    @Test
    func `manual partition repair returns credentials with one shared allowance`() async throws {
        let reads = LockIsolated(0)
        try await self.withFixture(reads: reads, interactive: true) {
            try await ClaudeOAuthCredentialsStore.withClaudeKeychainFingerprintStoreOverrideForTesting(.init()) {
                try await KeychainAccessPreflight.withPartitionCheckOverrideForTesting { _, _, _ in
                    .interactionRequired
                } operation: {
                    try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        try await BrowserCookieAccessGate.withExplicitRetry {
                            let data = try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                            #expect(data == self.payload)
                            #expect(throws: (any Error).self) {
                                try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                            }
                            #expect(reads.value == 1)
                        }
                    }
                }
            }
        }
    }

    @Test
    func `manual partition repair shares one prompt and preserves denial cooldown`() async {
        let reads = LockIsolated(0)
        await self.withFixture(reads: reads, readStatus: errSecUserCanceled, interactive: true) {
            await KeychainAccessPreflight.withPartitionCheckOverrideForTesting { _, _, _ in
                .interactionRequired
            } operation: {
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await BrowserCookieAccessGate.withExplicitRetry {
                        BrowserCookieKeychainAccessGate.withUserInteractionDisallowed {
                            #expect(throws: (any Error).self) {
                                try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                            }
                        }
                        #expect(reads.value == 0)
                        #expect(throws: (any Error).self) {
                            try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                        }
                        #expect(reads.value == 1)
                        #expect(throws: (any Error).self) {
                            try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                        }
                    }
                    _ = ClaudeOAuthKeychainAccessGate.clearDenied()
                    await BrowserCookieAccessGate.withExplicitRetry {
                        #expect(throws: (any Error).self) {
                            try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                        }
                    }
                    #expect(reads.value == 1)
                }
            }
        }
    }

    @Test
    func `always policy cannot delegate background or settings refreshes`() async {
        let touches = LockIsolated(0)
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(false) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    await ClaudeOAuthDelegatedRefreshCoordinator.withIsolatedStateForTesting {
                        await ClaudeOAuthDelegatedRefreshCoordinator.withCLIAvailableOverrideForTesting(true) {
                            await ClaudeOAuthDelegatedRefreshCoordinator.withKeychainFingerprintOverrideForTesting {
                                touches.value == 0 ? nil : .init(
                                    modifiedAt: touches.value, createdAt: 1, persistentRefHash: "synthetic-ref")
                            } operation: {
                                await ClaudeOAuthDelegatedRefreshCoordinator
                                    .withTouchAuthPathOverrideForTesting { _, _ in
                                        touches.setValue(touches.value + 1)
                                    } operation: {
                                        let background = await ProviderInteractionContext.$current
                                            .withValue(.background) {
                                                await ClaudeOAuthDelegatedRefreshCoordinator.attempt(timeout: 0)
                                            }
                                        #expect(background == .skippedByPromptPolicy)
                                        let settings = await ProviderInteractionContext.$current
                                            .withValue(.userInitiated) {
                                                let task = BrowserCookieKeychainAccessGate
                                                    .withUserInteractionDisallowed {
                                                        Task {
                                                            await ClaudeOAuthDelegatedRefreshCoordinator
                                                                .attempt(timeout: 0)
                                                        }
                                                    }
                                                return await task.value
                                            }
                                        #expect(settings == .skippedByPromptPolicy)
                                        #expect(touches.value == 0)
                                    }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
