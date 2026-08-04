import Foundation
import Testing
@testable import CodexBarCore

private final class UnreadableResultTouchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        self.lock.lock()
        self.value += 1
        self.lock.unlock()
    }

    func count() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

/// Regression coverage for #2634: the touch completes, but nothing this build reads holds the result.
@Suite(.serialized)
struct ClaudeOAuthDelegatedRefreshUnreadableResultTests {
    private static let unchangedFingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
        modifiedAt: 1,
        createdAt: 1,
        persistentRefHash: "ref1")

    private func makeCredentialsData(accessToken: String, expiresAt: Date) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexbar-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func attemptWithUnreadableKeychain(
        credentialsURL: URL,
        now: Date,
        touchAuthPath: @escaping @Sendable (TimeInterval, [String: String]) async throws -> Void)
        async throws -> ClaudeOAuthDelegatedRefreshCoordinator.AttemptResult
    {
        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(credentialsURL) {
                try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                        try await ClaudeOAuthDelegatedRefreshCoordinator.withIsolatedStateForTesting {
                            ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
                            defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
                            return try await ClaudeOAuthDelegatedRefreshCoordinator
                                .withKeychainFingerprintOverrideForTesting {
                                    Self.unchangedFingerprint
                                } operation: {
                                    try await ClaudeOAuthDelegatedRefreshCoordinator
                                        .withCLIAvailableOverrideForTesting(true) {
                                            try await ClaudeOAuthDelegatedRefreshCoordinator
                                                .withTouchAuthPathOverrideForTesting(touchAuthPath) {
                                                    await ClaudeOAuthDelegatedRefreshCoordinator.attemptDetailed(
                                                        now: now,
                                                        timeout: 0.1)
                                                }
                                        }
                                }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `unreadable refresh result reports terminal outcome instead of retryable failure`() async throws {
        let root = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let touches = UnreadableResultTouchCounter()
        let outcome = try await self.attemptWithUnreadableKeychain(
            credentialsURL: root.appendingPathComponent(".credentials.json"),
            now: Date(timeIntervalSince1970: 70000),
            // Succeeds while leaving the fingerprint untouched: Claude Code already refreshed.
            touchAuthPath: { _, _ in touches.increment() })

        #expect(outcome.isUnreadableAfterRefresh)
        // The touch still runs: on older Claude Code it can create the credentials file we would then read.
        #expect(touches.count() == 1)
    }

    @Test
    func `unchanged fingerprint stays retryable when a credentials file is present`() async throws {
        let root = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentialsURL = root.appendingPathComponent(".credentials.json")
        try self.makeCredentialsData(
            accessToken: "from-file",
            expiresAt: Date(timeIntervalSinceNow: 3600))
            .write(to: credentialsURL)

        let outcome = try await self.attemptWithUnreadableKeychain(
            credentialsURL: credentialsURL,
            now: Date(timeIntervalSince1970: 71000),
            touchAuthPath: { _, _ in })

        #expect(!outcome.isUnreadableAfterRefresh)
        guard case let .attemptedFailed(message) = outcome.outcome else {
            Issue.record("Expected .attemptedFailed, got \(outcome)")
            return
        }
        #expect(message.contains("did not update"))
    }
}
