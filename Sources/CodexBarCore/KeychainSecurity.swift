import Foundation

enum KeychainTestSafety {
    static let suppressAccessEnvironmentKey = "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"
    static let allowAccessEnvironmentKey = "CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"

    /// One-shot side effects when this process decides keychain access is blocked:
    /// export the suppression variable so spawned children (debug CLI binaries,
    /// PTY helpers) inherit the decision — name-based self-detection cannot cover
    /// arbitrary child process names — and turn off legacy-keychain interaction
    /// process-wide so no code path can raise the login-keychain ACL dialog.
    private nonisolated(unsafe) static var didApplyBlockedProcessSideEffects = false
    private static let blockedProcessSideEffectsLock = NSLock()

    private static func applyBlockedProcessSideEffectsOnce() {
        self.blockedProcessSideEffectsLock.lock()
        defer { self.blockedProcessSideEffectsLock.unlock() }
        guard !self.didApplyBlockedProcessSideEffects else { return }
        self.didApplyBlockedProcessSideEffects = true
        setenv(self.suppressAccessEnvironmentKey, "1", 1)
        #if os(macOS)
        KeychainLegacyInteraction.disableProcessWideInteraction()
        #endif
    }

    static func shouldBlockRealKeychainAccess(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let blocked = self.resolveShouldBlockRealKeychainAccess(
            processName: processName,
            environment: environment)
        if blocked {
            self.applyBlockedProcessSideEffectsOnce()
        }
        return blocked
    }

    /// Pure decision, side-effect free; kept separate for tests.
    static func resolveShouldBlockRealKeychainAccess(
        processName: String,
        environment: [String: String]) -> Bool
    {
        if environment[self.allowAccessEnvironmentKey] == "1" { return false }
        if environment[self.suppressAccessEnvironmentKey] == "1" { return true }
        if environment[KeychainAccessGate.disableAccessEnvironmentKey] == "1" { return true }
        return self.isRunningUnderTests(processName: processName, environment: environment)
    }

    static func shouldIsolateUserStateUnderTests(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        guard environment[self.allowAccessEnvironmentKey] != "1" else { return false }
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

/// Process-wide legacy-keychain interaction switch. `KeychainNoUIQuery` marks
/// individual queries non-interactive, but the repo has observed legacy ACL
/// dialogs surfacing regardless (see KeychainAccessPreflight); for processes
/// that must never prompt — test runners and suppressed children — flipping the
/// documented process-wide switch is the airtight variant. Resolved via dlsym
/// to avoid deprecation warnings, matching the existing pattern in
/// KeychainNoUIQuery/KeychainCacheStore.
enum KeychainLegacyInteraction {
    private typealias SetUserInteractionAllowedFn = @convention(c) (DarwinBoolean) -> OSStatus

    static func disableProcessWideInteraction() {
        guard let handle = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_LAZY | RTLD_NOLOAD) else { return }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecKeychainSetUserInteractionAllowed") else { return }
        let setUserInteractionAllowed = unsafeBitCast(symbol, to: SetUserInteractionAllowedFn.self)
        _ = setUserInteractionAllowed(false)
    }
}

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
