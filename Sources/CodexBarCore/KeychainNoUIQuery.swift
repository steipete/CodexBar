import Foundation

#if os(macOS)
import LocalAuthentication
import Security

enum KeychainNoUIQuery {
    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }
}
#endif
