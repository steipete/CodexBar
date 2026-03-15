import LocalAuthentication
import Security
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct KeychainNoUIQueryTests {
    @Test
    func apply_setsNonInteractiveAuthenticationContextAndLegacyNoUICompatibilityPolicy() {
        var query: [String: Any] = [:]

        KeychainNoUIQuery.apply(to: &query)

        #expect(query.count == 2)

        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        #expect(context != nil)
        #expect(context?.interactionNotAllowed == true)

        let uiPolicy = query[kSecUseAuthenticationUI as String] as? String
        #expect(uiPolicy == "u_AuthUIF")
    }
}
