import Foundation

#if os(macOS)
import LocalAuthentication
import Security

enum KeychainNoUIQuery {
    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // NOTE: LAContext.interactionNotAllowed is the modern way to prevent keychain UI prompts.
        // kSecUseAuthenticationUIFail was deprecated in macOS 12 and removed in later SDKs.
    }
}
#endif
