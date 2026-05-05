import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import Darwin
import LocalAuthentication
import Security

struct KeychainNoUIQueryTests {
    private func resolveSecurityUIFailValue() -> String {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }

    @Test
    func `apply sets non interactive context and UI fail policy`() {
        var query: [String: Any] = [:]

        KeychainNoUIQuery.apply(to: &query)

        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        #expect(context != nil)
        #expect(context?.interactionNotAllowed == true)

        let uiPolicy = query[kSecUseAuthenticationUI as String] as? String
        #expect(uiPolicy == self.resolveSecurityUIFailValue())
        #expect(uiPolicy == (KeychainNoUIQuery.uiFailPolicyForTesting() as String))
        #expect(uiPolicy != "kSecUseAuthenticationUIFail")
    }

    @Test
    func `preflight query is strictly non interactive and does not request secret data`() {
        let query = KeychainAccessPreflight.makeGenericPasswordPreflightQuery(
            service: "test.service",
            account: "test.account")

        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect((query[kSecUseAuthenticationUI as String] as? String) == self.resolveSecurityUIFailValue())
    }

    @Test
    func `preflight query executes without invalid UI policy`() {
        let query = KeychainAccessPreflight.makeGenericPasswordPreflightQuery(
            service: "codexbar.keychain.noui.\(UUID().uuidString)",
            account: nil)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecItemNotFound || status == errSecInteractionNotAllowed)
    }
}
#endif
