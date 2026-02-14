import Foundation

#if DEBUG
extension ClaudeOAuthCredentialsStore {
    final class CredentialsFileFingerprintStore: @unchecked Sendable {
        var fingerprint: CredentialsFileFingerprint?

        init(fingerprint: CredentialsFileFingerprint? = nil) {
            self.fingerprint = fingerprint
        }

        func load() -> CredentialsFileFingerprint? {
            self.fingerprint
        }

        func save(_ fingerprint: CredentialsFileFingerprint?) {
            self.fingerprint = fingerprint
        }
    }

    @TaskLocal static var taskKeychainAccessOverride: Bool?
    @TaskLocal static var taskCredentialsFileFingerprintStoreOverride: CredentialsFileFingerprintStore?

    static func withKeychainAccessOverrideForTesting<T>(
        _ disabled: Bool?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskKeychainAccessOverride.withValue(disabled) {
            try operation()
        }
    }

    static func withKeychainAccessOverrideForTesting<T>(
        _ disabled: Bool?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskKeychainAccessOverride.withValue(disabled) {
            try await operation()
        }
    }

    fileprivate static func withCredentialsFileFingerprintStoreOverrideForTesting<T>(
        _ store: CredentialsFileFingerprintStore?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskCredentialsFileFingerprintStoreOverride.withValue(store) {
            try operation()
        }
    }

    fileprivate static func withCredentialsFileFingerprintStoreOverrideForTesting<T>(
        _ store: CredentialsFileFingerprintStore?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskCredentialsFileFingerprintStoreOverride.withValue(store) {
            try await operation()
        }
    }

    static func withIsolatedCredentialsFileTrackingForTesting<T>(
        operation: () throws -> T) rethrows -> T
    {
        let store = CredentialsFileFingerprintStore()
        return try self.$taskCredentialsFileFingerprintStoreOverride.withValue(store) {
            try operation()
        }
    }

    static func withIsolatedCredentialsFileTrackingForTesting<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        let store = CredentialsFileFingerprintStore()
        return try await self.$taskCredentialsFileFingerprintStoreOverride.withValue(store) {
            try await operation()
        }
    }
}
#endif
