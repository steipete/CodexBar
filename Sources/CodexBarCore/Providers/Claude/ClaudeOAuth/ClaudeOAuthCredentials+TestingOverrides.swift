import Foundation

#if DEBUG
extension ClaudeOAuthCredentialsStore {
    nonisolated(unsafe) static var claudeKeychainDataOverride: Data?
    nonisolated(unsafe) static var claudeKeychainFingerprintOverride: ClaudeKeychainFingerprint?
    @TaskLocal static var taskClaudeKeychainDataOverride: Data?
    @TaskLocal static var taskClaudeKeychainFingerprintOverride: ClaudeKeychainFingerprint?
    @TaskLocal static var taskMemoryCacheStoreOverride: MemoryCacheStore?
    @TaskLocal static var taskClaudeKeychainFingerprintStoreOverride: ClaudeKeychainFingerprintStore?

    final class ClaudeKeychainFingerprintStore: @unchecked Sendable {
        var fingerprint: ClaudeKeychainFingerprint?

        init(fingerprint: ClaudeKeychainFingerprint? = nil) {
            self.fingerprint = fingerprint
        }
    }

    final class MemoryCacheStore: @unchecked Sendable {
        var record: ClaudeOAuthCredentialRecord?
        var timestamp: Date?
    }

    static func setClaudeKeychainDataOverrideForTesting(_ data: Data?) {
        self.claudeKeychainDataOverride = data
    }

    static func setClaudeKeychainFingerprintOverrideForTesting(_ fingerprint: ClaudeKeychainFingerprint?) {
        self.claudeKeychainFingerprintOverride = fingerprint
    }

    static func withClaudeKeychainOverridesForTesting<T>(
        data: Data?,
        fingerprint: ClaudeKeychainFingerprint?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskClaudeKeychainDataOverride.withValue(data) {
            try self.$taskClaudeKeychainFingerprintOverride.withValue(fingerprint) {
                try operation()
            }
        }
    }

    static func withClaudeKeychainOverridesForTesting<T>(
        data: Data?,
        fingerprint: ClaudeKeychainFingerprint?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskClaudeKeychainDataOverride.withValue(data) {
            try await self.$taskClaudeKeychainFingerprintOverride.withValue(fingerprint) {
                try await operation()
            }
        }
    }

    static func withClaudeKeychainFingerprintStoreOverrideForTesting<T>(
        _ store: ClaudeKeychainFingerprintStore?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskClaudeKeychainFingerprintStoreOverride.withValue(store) {
            try operation()
        }
    }

    static func withClaudeKeychainFingerprintStoreOverrideForTesting<T>(
        _ store: ClaudeKeychainFingerprintStore?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskClaudeKeychainFingerprintStoreOverride.withValue(store) {
            try await operation()
        }
    }

    static func withIsolatedMemoryCacheForTesting<T>(operation: () throws -> T) rethrows -> T {
        let store = MemoryCacheStore()
        return try self.$taskMemoryCacheStoreOverride.withValue(store) {
            try operation()
        }
    }

    static func withIsolatedMemoryCacheForTesting<T>(operation: () async throws -> T) async rethrows -> T {
        let store = MemoryCacheStore()
        return try await self.$taskMemoryCacheStoreOverride.withValue(store) {
            try await operation()
        }
    }

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

    enum SecurityCLIReadOverride: Sendable {
        case data(Data?)
        case timedOut
        case nonZeroExit
        case dynamic(@Sendable (SecurityCLIReadRequest) -> Data?)
    }

    @TaskLocal static var taskKeychainAccessOverride: Bool?
    @TaskLocal static var taskCredentialsFileFingerprintStoreOverride: CredentialsFileFingerprintStore?
    @TaskLocal static var taskSecurityCLIReadOverride: SecurityCLIReadOverride?
    @TaskLocal static var taskSecurityCLIReadAccountOverride: String?
    nonisolated(unsafe) static var securityCLIReadOverride: SecurityCLIReadOverride?

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

    static func withSecurityCLIReadOverrideForTesting<T>(
        _ readOverride: SecurityCLIReadOverride?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskSecurityCLIReadOverride.withValue(readOverride) {
            try operation()
        }
    }

    static func withSecurityCLIReadOverrideForTesting<T>(
        _ readOverride: SecurityCLIReadOverride?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskSecurityCLIReadOverride.withValue(readOverride) {
            try await operation()
        }
    }

    static func withSecurityCLIReadAccountOverrideForTesting<T>(
        _ account: String?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskSecurityCLIReadAccountOverride.withValue(account) {
            try operation()
        }
    }

    static func withSecurityCLIReadAccountOverrideForTesting<T>(
        _ account: String?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskSecurityCLIReadAccountOverride.withValue(account) {
            try await operation()
        }
    }

    static func setSecurityCLIReadOverrideForTesting(_ readOverride: SecurityCLIReadOverride?) {
        self.securityCLIReadOverride = readOverride
    }
}
#endif
