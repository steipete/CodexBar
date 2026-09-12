import Foundation
import Testing
@testable import CodexBarCore

struct KeychainAccessGateDefaultsTests {
    @Test(arguments: [
        ("swiftpm-testing-helper", [:]),
        ("CodexBarPackageTests", [:]),
        ("test-child", ["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1"]),
        ("test-child", ["SWIFT_TESTING": "1"]),
    ] as [(String, [String: String])])
    func `uninitialized gate fallback never resolves defaults under automatic test safety`(
        processName: String,
        environment: [String: String])
    {
        var resolutions: [String] = []
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "debugDisableKeychainAccess")

        let explicitlyDisabled = KeychainAccessGate.defaultsDisableAccess(
            processName: processName,
            environment: environment,
            standardDefaults: {
                resolutions.append("standard")
                return defaults
            },
            sharedDefaults: {
                resolutions.append("shared")
                return defaults
            })

        #expect(!explicitlyDisabled)
        #expect(resolutions.isEmpty)
    }

    @Test(arguments: [nil, false, true] as [Bool?], [nil, false, true] as [Bool?])
    func `deliberate live opt in retains defaults fallback without accessing live stores`(
        standardValue: Bool?, sharedValue: Bool?)
    {
        let standard = InMemoryUserDefaults()
        let shared = InMemoryUserDefaults()
        if let standardValue {
            standard.set(standardValue, forKey: "debugDisableKeychainAccess")
        }
        if let sharedValue {
            shared.set(sharedValue, forKey: "debugDisableKeychainAccess")
        }
        var resolutions: [String] = []

        let explicitlyDisabled = KeychainAccessGate.defaultsDisableAccess(
            processName: "swiftpm-testing-helper",
            environment: [
                "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1",
                "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            ],
            standardDefaults: {
                resolutions.append("standard")
                return standard
            },
            sharedDefaults: {
                resolutions.append("shared")
                return shared
            })

        #expect(explicitlyDisabled == (standardValue == true || sharedValue == true))
        #expect(resolutions == (standardValue == true ? ["standard"] : ["standard", "shared"]))
    }

    @Test
    func `production fallback still uses the supplied defaults`() {
        let shared = InMemoryUserDefaults()
        shared.set(true, forKey: "debugDisableKeychainAccess")

        #expect(KeychainAccessGate.defaultsDisableAccess(
            processName: "CodexBar",
            environment: [:],
            standardDefaults: { InMemoryUserDefaults() },
            sharedDefaults: { shared }))
    }

    @Test(arguments: [false, true])
    func `automatic suppression is distinct from an explicit stored override`(disabled: Bool) throws {
        try self.requireOrdinaryTestSafety()
        KeychainAccessGate.withStoredOverrideForTesting(disabled) {
            #expect(KeychainAccessGate.isDisabled)
            #expect(KeychainAccessGate.isExplicitlyDisabled == disabled)
        }
    }

    @Test(arguments: [false, true])
    func `task override keeps precedence over automatic safety and stored overrides`(disabled: Bool) {
        KeychainAccessGate.withStoredOverrideForTesting(!disabled) {
            KeychainAccessGate.withTaskOverrideForTesting(disabled) {
                #expect(KeychainAccessGate.isDisabled == disabled)
                #expect(KeychainAccessGate.isExplicitlyDisabled == disabled)
            }
        }
    }

    private func requireOrdinaryTestSafety() throws {
        try #require(KeychainTestSafety.resolveShouldBlockRealKeychainAccess(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment))
        try #require(!KeychainAccessGate.isDisabledByEnvironment())
        try #require(KeychainAccessGate.processDisableReason == nil)
    }
}
