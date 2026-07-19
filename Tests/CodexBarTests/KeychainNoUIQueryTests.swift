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

    @Test
    func `processes block every Security item operation before system access`() {
        guard ProcessInfo.processInfo.environment[KeychainTestSafety.allowAccessEnvironmentKey] != "1" else {
            return
        }

        #expect(KeychainTestSafety.shouldBlockRealKeychainAccess())

        let empty = [:] as CFDictionary
        var result: CFTypeRef?
        #expect(KeychainSecurity.copyMatching(empty, &result) == errSecInteractionNotAllowed)
        #expect(KeychainSecurity.update(empty, empty) == errSecInteractionNotAllowed)
        #expect(KeychainSecurity.add(empty, nil) == errSecInteractionNotAllowed)
        #expect(KeychainSecurity.delete(empty) == errSecInteractionNotAllowed)
    }

    @Test
    func `safety recognizes runner variants and explicit controls`() {
        #expect(KeychainTestSafety.shouldBlockRealKeychainAccess(
            processName: "swiftpm-testing-helper",
            environment: [:]))
        #expect(KeychainTestSafety.shouldBlockRealKeychainAccess(
            processName: "CodexBarPackageTests.xctest",
            environment: [:]))
        #expect(KeychainTestSafety.shouldBlockRealKeychainAccess(
            processName: "future-test-runner",
            environment: [KeychainTestSafety.suppressAccessEnvironmentKey: "1"]))
        #expect(KeychainTestSafety.shouldBlockRealKeychainAccess(
            processName: "CodexBar",
            environment: [:]) == false)
        #expect(KeychainTestSafety.shouldBlockRealKeychainAccess(
            processName: "swiftpm-testing-helper",
            environment: [KeychainTestSafety.allowAccessEnvironmentKey: "1"]) == false)
    }
}
#endif
