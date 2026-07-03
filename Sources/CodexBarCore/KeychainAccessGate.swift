import Foundation
#if canImport(SweetCookieKit)
import SweetCookieKit
#endif

public enum KeychainAccessGate {
    private static let flagKey = "debugDisableKeychainAccess"
    static let disableAccessEnvironmentKey = "CODEXBAR_DISABLE_KEYCHAIN_ACCESS"
    @TaskLocal private static var taskOverrideValue: Bool?
    private nonisolated(unsafe) static var overrideValue: Bool?
    private static let processForceDisabledLock = NSLock()
    private nonisolated(unsafe) static var processForceDisabledReason: String?

    public nonisolated(unsafe) static var isDisabled: Bool {
        get {
            if let taskOverrideValue { return taskOverrideValue }
            if self.isDisabledByEnvironment() { return true }
            #if DEBUG
            if Self.forcesDisabledUnderTests {
                return true
            }
            #endif
            if self.processDisableReason != nil { return true }
            if let overrideValue { return overrideValue }
            if UserDefaults.standard.bool(forKey: Self.flagKey) { return true }
            if let shared = AppGroupSupport.sharedDefaults(), shared.bool(forKey: Self.flagKey) {
                return true
            }
            return false
        }
        set {
            overrideValue = newValue
            #if os(macOS) && canImport(SweetCookieKit)
            BrowserCookieKeychainAccessGate.isDisabled = self.isDisabled
            #endif
        }
    }

    static func isDisabledByEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        environment[self.disableAccessEnvironmentKey] == "1"
    }

    public static func forceDisabledForProcess(reason: String) {
        self.processForceDisabledLock.lock()
        self.processForceDisabledReason = reason
        self.processForceDisabledLock.unlock()
        #if os(macOS) && canImport(SweetCookieKit)
        BrowserCookieKeychainAccessGate.isDisabled = self.isDisabled
        #endif
    }

    public static var processDisableReason: String? {
        self.processForceDisabledLock.lock()
        defer { self.processForceDisabledLock.unlock() }
        return self.processForceDisabledReason
    }

    #if DEBUG
    private nonisolated(unsafe) static var forcesDisabledUnderTests: Bool {
        self.isRunningUnderTests
            && ProcessInfo.processInfo.environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
    }

    private nonisolated(unsafe) static var isRunningUnderTests: Bool {
        let processName = ProcessInfo.processInfo.processName
        return processName == "swiftpm-testing-helper"
            || processName.hasSuffix("PackageTests")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    #endif

    static func withTaskOverrideForTesting<T>(
        _ disabled: Bool?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverrideValue.withValue(disabled) {
            try operation()
        }
    }

    static func withTaskOverrideForTesting<T>(
        _ disabled: Bool?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverrideValue.withValue(disabled) {
            try await operation()
        }
    }

    static var currentOverrideForTesting: Bool? {
        self.taskOverrideValue ?? self.overrideValue
    }

    #if DEBUG
    static func resetOverrideForTesting() {
        self.overrideValue = nil
        self.processForceDisabledLock.lock()
        self.processForceDisabledReason = nil
        self.processForceDisabledLock.unlock()
        #if os(macOS) && canImport(SweetCookieKit)
        BrowserCookieKeychainAccessGate.isDisabled = self.isDisabled
        #endif
    }
    #endif
}
