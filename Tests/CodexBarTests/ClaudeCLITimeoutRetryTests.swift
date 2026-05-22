import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
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

    private final class WebRequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            self.lock.withLock {
                self.paths.append(path)
            }
        }

        func snapshot() -> [String] {
            self.lock.withLock {
                self.paths
            }
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
    func `auto cli usage does not retry unrecoverable parse failure`() async throws {
        let attempts = AttemptRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .auto,
            manualCookieHeader: "foo=bar")

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            _ = await attempts.record(timeout: timeout)
            throw ClaudeStatusProbeError.parseFailed("Missing Current session.")
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
    func `auto cli usage retries loading panel before stale web fallback`() async throws {
        let attempts = AttemptRecorder()
        let webRequests = WebRequestRecorder()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .auto,
            manualCookieHeader: "sessionKey=sk-ant-session-token")

        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
            let attempt = await attempts.record(timeout: timeout)
            if attempt == 1 {
                throw ClaudeStatusProbeError.parseFailed("Claude CLI /usage is still loading usage data.")
            }
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 95,
                weeklyPercentLeft: 93,
                opusPercentLeft: nil,
                accountEmail: "loading-cli@example.com",
                accountOrganization: "Loading CLI Org",
                loginMethod: "cli",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }

        let snapshot = try await self.withNoOAuthCredentials {
            try await self.withClaudeWebStub(handler: { request in
                webRequests.record(request.url?.path ?? "<missing>")
                throw URLError(.userAuthenticationRequired)
            }, operation: {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            })
        }

        let recorded = await attempts.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded.timeouts == [12, 60])
        #expect(webRequests.snapshot().isEmpty)
        #expect(snapshot.primary.usedPercent == 5)
        #expect(snapshot.secondary?.usedPercent == 7)
        #expect(snapshot.accountEmail == "loading-cli@example.com")
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

    private func withClaudeWebStub<T>(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: () async throws -> T) async rethrows -> T
    {
        let registered = URLProtocol.registerClass(ClaudeAutoFetcherStubURLProtocol.self)
        ClaudeAutoFetcherStubURLProtocol.handler = handler
        defer {
            if registered {
                URLProtocol.unregisterClass(ClaudeAutoFetcherStubURLProtocol.self)
            }
            ClaudeAutoFetcherStubURLProtocol.handler = nil
        }
        return try await operation()
    }
}
