#if os(macOS)
import Foundation
import Security
import Testing
@testable import CodexBarCore

struct ClaudeSecurityCLIPromptPolicyTests {
    @Test(arguments: [
        errSecSuccess,
        errSecItemNotFound,
        errSecInteractionNotAllowed,
        errSecUserCanceled,
        errSecAuthFailed,
        errSecNoAccessForItem,
        errSecParam,
    ], [false, true])
    func `shared data read status mapping preserves prompt cooldown semantics`(status: OSStatus, interactive: Bool) {
        let denied = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
        let data = Data("synthetic".utf8)
        var returned: Data?
        var failure: Int?
        ClaudeOAuthKeychainAccessGate.withDeniedUntilStoreOverrideForTesting(denied) {
            do {
                returned = try ClaudeOAuthCredentialsStore.claudeKeychainDataResult(
                    status: status, result: data as NSData, allowKeychainPrompt: interactive)
            } catch let ClaudeOAuthCredentialsError.keychainError(code) {
                failure = code
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        let silentMiss = status == errSecItemNotFound || status == errSecInteractionNotAllowed && !interactive
        #expect(returned == (status == errSecSuccess ? data : nil))
        #expect(failure == (status == errSecSuccess || silentMiss ? nil : Int(status)))
        let shouldDeny = [errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem].contains(status)
            || status == errSecInteractionNotAllowed && interactive
        #expect((denied.deniedUntil != nil) == shouldDeny)
    }

    @Test(arguments: ClaudeOAuthKeychainPromptMode.allCases, [ProviderInteraction.background, .userInitiated])
    func `security CLI launch respects stored prompt policy`(
        mode: ClaudeOAuthKeychainPromptMode,
        interaction: ProviderInteraction)
    {
        let reads = LockIsolated(0)
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(true) {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(mode) {
                    ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.dynamic { _ in
                        reads.setValue(reads.value + 1)
                        return nil
                    }) {
                        _ = ClaudeOAuthCredentialsStore.readRawClaudeKeychainPayloadViaSecurityCLIIfEnabled(
                            interaction: interaction,
                            readStrategy: .securityCLIExperimental,
                            environment: [:])
                    }
                }
            }
        }
        let allowed = mode == .always || (mode == .onlyOnUserAction && interaction == .userInitiated)
        #expect(reads.value == (allowed ? 1 : 0))
    }
}
#endif
