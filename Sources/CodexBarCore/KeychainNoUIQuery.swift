import Foundation

#if os(macOS)
import LocalAuthentication
import Security

enum KeychainNoUIQuery {
    private static let legacyAuthenticationUIFailValue = "u_AuthUIF"

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true

        // On our macOS 14+ target, the supported non-interactive keychain path is an LAContext with
        // interaction disabled. We also keep the legacy "fail instead of prompt" policy because some
        // external keychain items still use the legacy keychain behavior on macOS.
        query[kSecUseAuthenticationContext as String] = context
        // Preserve the old fail-without-prompt behavior without referencing the deprecated constant directly.
        query[kSecUseAuthenticationUI as String] = Self.legacyAuthenticationUIFailValue
    }
}
#endif
