import Foundation
#if canImport(SweetCookieKit)
import SweetCookieKit
#endif

public enum KeychainAccessGate {
    private static let flagKey = "debugDisableKeychainAccess"
    @TaskLocal private static var taskOverrideValue: Bool?
    private nonisolated(unsafe) static var overrideValue: Bool?

    public nonisolated(unsafe) static var isDisabled: Bool {
        get {
            if let taskOverrideValue { return taskOverrideValue }
            #if DEBUG
            if Self.forcesDisabledUnderTests {
                return true
            }
            #endif
            if let overrideValue { return overrideValue }
            if UserDefaults.standard.bool(forKey: Self.flagKey) { return true }
            for appGroupID in AppIdentity.appGroupIDs(for: Bundle.main.bundleIdentifier) {
                if let shared = UserDefaults(suiteName: appGroupID),
                   shared.bool(forKey: Self.flagKey)
                {
                    return true
                }
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
        #if os(macOS) && canImport(SweetCookieKit)
        BrowserCookieKeychainAccessGate.isDisabled = self.isDisabled
        #endif
    }
    #endif
}
