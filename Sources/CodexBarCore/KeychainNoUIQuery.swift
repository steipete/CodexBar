import Foundation

#if os(macOS)
import LocalAuthentication
import Security

enum KeychainNoUIQuery {
    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // Keep explicit UI-fail policy for legacy keychain behavior on macOS where
        // `interactionNotAllowed` alone can still surface Allow/Deny prompts.
        // Use the raw constant value to avoid deprecation warnings while preserving behavior.
        query[kSecUseAuthenticationUI as String] = "kSecUseAuthenticationUIFail" as CFString
    }
}
#endif
