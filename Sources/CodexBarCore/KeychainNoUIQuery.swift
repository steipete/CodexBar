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
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
}
#endif
