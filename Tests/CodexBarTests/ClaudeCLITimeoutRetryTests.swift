import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeCLITimeoutRetryTests {
    private actor AttemptRecorder {
        private var count = 0
        private var timeouts: [TimeInterval] = []

        func record(timeout: TimeInterval) -> Int {
            self.count += 1
            self.timeouts.append(timeout)
            return self.count
        }

        func snapshot() -> (count: Int, timeouts: [TimeInterval]) {
            (self.count, self.timeouts)
        }
    }

    @Test
    func `cli usage retries with longer timeout after transient probe failure`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            let attempt = await attempts.record(timeout: timeout)
            if attempt == 1 {
                throw ClaudeStatusProbeError.timedOut
            }
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 91,
                weeklyPercentLeft: 88,
                opusPercentLeft: nil,
                accountEmail: "cli@example.com",
                accountOrganization: "CLI Org",
                loginMethod: "cli",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        let snapshot = try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                try await fetcher.loadLatestUsage(model: "sonnet")
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded.timeouts == [24, 60])
        #expect(snapshot.primary.usedPercent == 9)
        #expect(snapshot.secondary?.usedPercent == 12)
        #expect(snapshot.accountEmail == "cli@example.com")
    }

    @Test
    func `auto cli usage uses bounded timeout without long retry`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .auto,
            manualCookieHeader: "foo=bar")

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            _ = await attempts.record(timeout: timeout)
            throw ClaudeStatusProbeError.parseFailed("Claude CLI /usage is still loading usage data.")
        }

        await #expect(throws: ClaudeStatusProbeError.self) {
            try await self.withNoOAuthCredentials {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded.timeouts == [12])
    }

    @Test
    func `auto cli usage retries timeout when cli is final source`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .auto,
            manualCookieHeader: "foo=bar")

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            let attempt = await attempts.record(timeout: timeout)
            if attempt == 1 {
                throw ClaudeStatusProbeError.timedOut
            }
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 72,
                weeklyPercentLeft: 64,
                opusPercentLeft: nil,
                accountEmail: "auto-cli@example.com",
                accountOrganization: "Auto CLI Org",
                loginMethod: "cli",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        let snapshot = try await self.withNoOAuthCredentials {
            try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                    try await fetcher.loadLatestUsage(model: "sonnet")
                }
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded.timeouts == [12, 60])
        #expect(snapshot.primary.usedPercent == 28)
        #expect(snapshot.secondary?.usedPercent == 36)
        #expect(snapshot.accountEmail == "auto-cli@example.com")
    }

    @Test
    func `cli usage does not retry cancelled probe`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            _ = await attempts.record(timeout: timeout)
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                    try await fetcher.loadLatestUsage(model: "sonnet")
                }
            }
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded.timeouts == [24])
    }

    private func withNoOAuthCredentials<T>(operation: () async throws -> T) async rethrows -> T {
        let missingCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-claude-creds-\(UUID().uuidString).json")
        return try await KeychainCacheStore.withServiceOverrideForTesting("rat-107-\(UUID().uuidString)") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            return try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            try await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: nil,
                                fingerprint: nil)
                            {
                                try await operation()
                            }
                        }
                    }
                }
            }
        }
    }
}
