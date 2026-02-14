import Foundation

#if os(macOS)
import LocalAuthentication
import Security

enum KeychainNoUIQuery {
    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // NOTE: While Apple recommends using LAContext.interactionNotAllowed, that alone is not sufficient to
        // prevent the legacy keychain "Allow/Deny" prompt on some configurations. We also set the UI policy to fail
        // so SecItemCopyMatching returns errSecInteractionNotAllowed instead of showing UI.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
}
#endif
