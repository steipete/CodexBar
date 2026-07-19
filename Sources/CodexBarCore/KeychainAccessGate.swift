import Foundation
#if canImport(SweetCookieKit)
import SweetCookieKit
#endif

public enum KeychainAccessGate {
    private static let flagKey = "debugDisableKeychainAccess"
    static let disableAccessEnvironmentKey = "CODEXBAR_DISABLE_KEYCHAIN_ACCESS"
    @TaskLocal private static var taskOverrideValue: Bool?
    // All mutable gate state and mirror writes share this lock. Resolve the effective value with
    // `isDisabledLocked()` instead of recursively entering through the public getter.
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var overrideValue: Bool?
    private nonisolated(unsafe) static var processForceDisabledReason: String?

    public nonisolated(unsafe) static var isDisabled: Bool {
        get {
            self.stateLock.withLock { self.isDisabledLocked() }
        }
        set {
            self.stateLock.withLock {
                self.overrideValue = newValue
                self.updateBrowserCookieMirrorLocked()
            }
        }
    }

    private static func isDisabledLocked() -> Bool {
        if let taskOverrideValue { return taskOverrideValue }
        if self.isDisabledByEnvironment() { return true }
        #if DEBUG
        if Self.forcesDisabledUnderTests { return true }
        #endif
        if self.processForceDisabledReason != nil { return true }
        if let overrideValue { return overrideValue }
        if UserDefaults.standard.bool(forKey: Self.flagKey) { return true }
        if let shared = AppGroupSupport.sharedDefaults(), shared.bool(forKey: Self.flagKey) { return true }
        return false
    }

    private static func updateBrowserCookieMirrorLocked() {
        #if os(macOS) && canImport(SweetCookieKit)
        BrowserCookieKeychainAccessGate.isDisabled = self.isDisabledLocked()
        #endif
    }

    static func isDisabledByEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        environment[self.disableAccessEnvironmentKey] == "1"
    }

    public static func forceDisabledForProcess(reason: String) {
        self.stateLock.withLock {
            self.processForceDisabledReason = reason
            self.updateBrowserCookieMirrorLocked()
        }
    }

    public static var processDisableReason: String? {
        self.stateLock.withLock { self.processForceDisabledReason }
    }

    #if DEBUG
    private nonisolated(unsafe) static var forcesDisabledUnderTests: Bool {
        KeychainTestSafety.shouldBlockRealKeychainAccess()
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
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverrideValue.withValue(disabled) {
            try await operation()
        }
    }

    static var currentOverrideForTesting: Bool? {
        self.taskOverrideValue ?? self.stateLock.withLock { self.overrideValue }
    }

    #if DEBUG
    static func resetOverrideForTesting() {
        self.stateLock.withLock {
            self.overrideValue = nil
            self.processForceDisabledReason = nil
            self.updateBrowserCookieMirrorLocked()
        }
    }
    #endif
}
