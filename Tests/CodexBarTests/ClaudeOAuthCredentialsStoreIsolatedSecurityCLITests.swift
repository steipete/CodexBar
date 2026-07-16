import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreIsolatedSecurityCLITests {
    @Test
    func `safety blocks security CLI access to the login keychain`() {
        let blockedEnvironment = [KeychainTestSafety.suppressAccessEnvironmentKey: "1"]
        #expect(ClaudeOAuthCredentialsStore.securityCLIReadArguments(
            account: nil,
            environment: blockedEnvironment) == nil)

        let explicitOptIn = [
            KeychainTestSafety.suppressAccessEnvironmentKey: "1",
            KeychainTestSafety.allowAccessEnvironmentKey: "1",
        ]
        let expectedArguments = [
            "find-generic-password",
            "-s",
            "Claude Code-credentials",
            "-w",
        ]
        #expect(ClaudeOAuthCredentialsStore.securityCLIReadArguments(
            account: nil,
            environment: explicitOptIn) == expectedArguments)
    }

    @Test
    func `isolated security CLI keychain requires global keychain disable`() {
        let keychainPath = "/tmp/codexbar-fixtures/verify.keychain-db"
        let isolatedEnvironment = [
            KeychainAccessGate.disableAccessEnvironmentKey: "1",
            ClaudeOAuthCredentialsStore.isolatedSecurityCLIKeychainEnvironmentKey: keychainPath,
        ]
        let expectedArguments = [
            "find-generic-password",
            "-s",
            "Claude Code-credentials",
            "-w",
            keychainPath,
        ]

        #expect(KeychainAccessGate.isDisabledByEnvironment(isolatedEnvironment))
        #expect(ClaudeOAuthCredentialsStore.securityCLIReadArguments(
            account: nil,
            environment: isolatedEnvironment) == expectedArguments)
        #expect(ClaudeOAuthCredentialsStore.securityCLIReadArguments(
            account: nil,
            environment: [
                ClaudeOAuthCredentialsStore.isolatedSecurityCLIKeychainEnvironmentKey: keychainPath,
            ]) == nil)
        #expect(ClaudeOAuthCredentialsStore.securityCLIReadArguments(
            account: nil,
            environment: [KeychainAccessGate.disableAccessEnvironmentKey: "1"]) == nil)
        #expect(ClaudeOAuthCredentialsStore.securityCLIReadArguments(
            account: nil,
            environment: [
                KeychainAccessGate.disableAccessEnvironmentKey: "1",
                ClaudeOAuthCredentialsStore.isolatedSecurityCLIKeychainEnvironmentKey: "relative.keychain-db",
            ]) == nil)
    }

    @Test
    func `isolated security CLI keychain remains readable while other keychain access is disabled`() {
        let mcpOnlyPayload = Data(#"{"mcpOAuth":{"plugin:test":{"accessToken":"synthetic"}}}"#.utf8)
        let environment = [
            KeychainAccessGate.disableAccessEnvironmentKey: "1",
            ClaudeOAuthCredentialsStore.isolatedSecurityCLIKeychainEnvironmentKey: "/tmp/verify.keychain-db",
        ]

        let isMcpOnly = ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(mcpOnlyPayload)) {
            ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
                interaction: .background,
                readStrategy: .securityCLIExperimental,
                keychainAccessDisabled: true,
                environment: environment)
        }
        #expect(isMcpOnly)

        let blockedWithoutIsolatedKeychain = ClaudeOAuthCredentialsStore
            .withSecurityCLIReadOverrideForTesting(.data(mcpOnlyPayload)) {
                ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
                    interaction: .background,
                    readStrategy: .securityCLIExperimental,
                    keychainAccessDisabled: true,
                    environment: [KeychainAccessGate.disableAccessEnvironmentKey: "1"])
            }
        #expect(blockedWithoutIsolatedKeychain == false)
    }

    @Test
    func `never prompt mode still detects MCP-only payload via experimental security CLI reader`() {
        let mcpOnlyPayload = Data(#"{"mcpOAuth":{"plugin:test":{"accessToken":"synthetic"}}}"#.utf8)
        let environment = [
            KeychainAccessGate.disableAccessEnvironmentKey: "1",
            ClaudeOAuthCredentialsStore.isolatedSecurityCLIKeychainEnvironmentKey: "/tmp/verify.keychain-db",
        ]

        let isMcpOnly = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(mcpOnlyPayload)) {
                ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
                    interaction: .background,
                    readStrategy: .securityCLIExperimental,
                    keychainAccessDisabled: true,
                    environment: environment)
            }
        }
        #expect(!isMcpOnly)

        let blockedViaSecurityFramework = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(mcpOnlyPayload)) {
                ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
                    interaction: .background,
                    readStrategy: .securityFramework,
                    keychainAccessDisabled: false,
                    environment: [:])
            }
        }
        #expect(!blockedViaSecurityFramework)
    }
}
#endif
