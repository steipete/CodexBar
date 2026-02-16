import LocalAuthentication
import Security
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite
struct KeychainNoUIQueryTests {
    @Test
    func apply_setsNonInteractiveContextAndUIFailPolicy() {
        var query: [String: Any] = [:]

        KeychainNoUIQuery.apply(to: &query)

        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        #expect(context != nil)
        #expect(context?.interactionNotAllowed == true)

        let uiPolicy = query[kSecUseAuthenticationUI as String] as? String
        #expect(uiPolicy == "kSecUseAuthenticationUIFail")
    }

    @Test
    func preflightQuery_isStrictlyNonInteractiveAndDoesNotRequestSecretData() {
        let query = KeychainAccessPreflight.makeGenericPasswordPreflightQuery(
            service: "test.service",
            account: "test.account")

        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect((query[kSecUseAuthenticationUI as String] as? String) == "kSecUseAuthenticationUIFail")
    }
}
#endif
