import Foundation

#if DEBUG
extension CookieHeaderCache {
    static func withDisplayStalenessIntervalOverrideForTesting<T>(
        _ interval: TimeInterval?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskDisplayStalenessIntervalOverride.withValue(interval) {
            try operation()
        }
    }

    static func withDisplayStalenessIntervalOverrideForTesting<T>(
        _ interval: TimeInterval?,
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskDisplayStalenessIntervalOverride.withValue(interval) {
            try await operation()
        }
    }

    static func withDisplayUnavailableRetryIntervalOverrideForTesting<T>(
        _ interval: TimeInterval?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskDisplayUnavailableRetryIntervalOverride.withValue(interval) {
            try operation()
        }
    }

    static func withDisplayUnavailableRetryIntervalOverrideForTesting<T>(
        _ interval: TimeInterval?,
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskDisplayUnavailableRetryIntervalOverride.withValue(interval) {
            try await operation()
        }
    }
}
#endif
