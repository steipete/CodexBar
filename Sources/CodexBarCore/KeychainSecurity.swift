import Foundation

enum KeychainTestSafety {
    static let suppressAccessEnvironmentKey = "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"
    static let allowAccessEnvironmentKey = "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"

    static func shouldBlockRealKeychainAccess(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        if environment[self.allowAccessEnvironmentKey] == "1" { return false }
        if environment[self.suppressAccessEnvironmentKey] == "1" { return true }
        if environment[KeychainAccessGate.disableAccessEnvironmentKey] == "1" { return true }
        return self.isRunningUnderTests(processName: processName, environment: environment)
    }

    static func isRunningUnderTests(
        processName: String,
        environment: [String: String]) -> Bool
    {
        processName == "swiftpm-testing-helper"
            || processName.hasSuffix("PackageTests")
            || processName.hasSuffix(".xctest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["TESTING_LIBRARY_VERSION"] != nil
            || environment["SWIFT_TESTING"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
    }
}

#if os(macOS)
import Security

/// The only first-party entry point for Security.framework item operations.
/// Test processes fail closed before touching the user's Keychain, even when a test enables
/// higher-level Keychain logic with `KeychainAccessGate.withTaskOverrideForTesting(false)`.
public enum KeychainSecurity {
    public static func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    {
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        return SecItemCopyMatching(query, result)
    }

    public static func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        return SecItemUpdate(query, attributesToUpdate)
    }

    public static func add(
        _ attributes: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    {
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        return SecItemAdd(attributes, result)
    }

    public static func delete(_ query: CFDictionary) -> OSStatus {
        guard !KeychainTestSafety.shouldBlockRealKeychainAccess() else {
            return errSecInteractionNotAllowed
        }
        return SecItemDelete(query)
    }
}
#endif
