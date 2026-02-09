import Foundation
#if canImport(SweetCookieKit)
import SweetCookieKit
#endif

public enum KeychainAccessGate {
    private static let flagKey = "debugDisableKeychainAccess"
    private static let appGroupID = "group.com.steipete.codexbar"
    @TaskLocal private static var taskOverrideValue: Bool?
    private nonisolated(unsafe) static var overrideValue: Bool?

    public nonisolated(unsafe) static var isDisabled: Bool {
        get {
            if let taskOverrideValue { return taskOverrideValue }
            if let overrideValue { return overrideValue }
            if UserDefaults.standard.bool(forKey: Self.flagKey) { return true }
            if let shared = UserDefaults(suiteName: Self.appGroupID),
               shared.bool(forKey: Self.flagKey)
            {
                return true
            }
            return false
        }
        set {
            overrideValue = newValue
            #if os(macOS) && canImport(SweetCookieKit)
            BrowserCookieKeychainAccessGate.isDisabled = newValue
            #endif
        }
    }

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
}
