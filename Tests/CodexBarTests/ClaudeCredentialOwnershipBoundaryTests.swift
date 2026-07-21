import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeCredentialOwnershipBoundaryTests {
    @Test(arguments: [
        ClaudeOAuthKeychainPromptMode.never,
        ClaudeOAuthKeychainPromptMode.onlyOnUserAction,
        ClaudeOAuthKeychainPromptMode.always,
    ])
    func `production ownership boundary rejects Claude Code keychain under every prompt mode`(
        mode: ClaudeOAuthKeychainPromptMode)
    {
        ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(mode) {
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                #expect(ClaudeOAuthCredentialsStore.directClaudeCodeKeychainAccessAllowedForTesting == false)

                let data = ClaudeOAuthCredentialsStore.readRawClaudeKeychainPayloadViaSecurityCLIIfEnabled(
                    interaction: .userInitiated,
                    readStrategy: .securityCLIExperimental)
                #expect(data == nil)
                #expect(
                    ClaudeOAuthCredentialsStore.readRawClaudeKeychainPayloadViaSecurityFrameworkWithoutPrompt()
                        == nil)
                #expect(ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt() == false)
            }
        }
    }
}
