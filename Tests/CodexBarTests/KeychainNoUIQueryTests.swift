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
        #expect(uiPolicy == (kSecUseAuthenticationUIFail as String))
    }
}
#endif
