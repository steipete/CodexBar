import Foundation

#if DEBUG
extension ClaudeOAuthCredentialsStore {
    final class ClaudeKeychainOverrideStore: @unchecked Sendable {
        var data: Data?
        var fingerprint: ClaudeKeychainFingerprint?

        init(data: Data? = nil, fingerprint: ClaudeKeychainFingerprint? = nil) {
            self.data = data
            self.fingerprint = fingerprint
        }
    }

    @TaskLocal static var taskClaudeKeychainOverrideStore: ClaudeKeychainOverrideStore?

    static func withMutableClaudeKeychainOverrideStoreForTesting<T>(
        _ store: ClaudeKeychainOverrideStore?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskClaudeKeychainOverrideStore.withValue(store) {
            try operation()
        }
    }

    static func withMutableClaudeKeychainOverrideStoreForTesting<T>(
        _ store: ClaudeKeychainOverrideStore?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskClaudeKeychainOverrideStore.withValue(store) {
            try await operation()
        }
    }
}
#endif
