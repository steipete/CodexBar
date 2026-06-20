import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
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

    private func withIsolatedRateLimitGate<T>(_ operation: () async throws -> T) async throws -> T {
        let suiteName = "ClaudeCLITimeoutRetryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try await ClaudeCLIRateLimitGate.withUserDefaultsForTesting(defaults) {
            ClaudeCLIRateLimitGate.resetForTesting()
            return try await operation()
        }
    }

    @Test
    func `cli usage retries with longer timeout after transient probe failure`() async throws {
        ClaudeCLIRateLimitGate.resetForTesting()
        defer { ClaudeCLIRateLimitGate.resetForTesting() }

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
        ClaudeCLIRateLimitGate.resetForTesting()
        defer { ClaudeCLIRateLimitGate.resetForTesting() }

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
        ClaudeCLIRateLimitGate.resetForTesting()
        defer { ClaudeCLIRateLimitGate.resetForTesting() }

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
        ClaudeCLIRateLimitGate.resetForTesting()
        defer { ClaudeCLIRateLimitGate.resetForTesting() }

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
        ClaudeCLIRateLimitGate.resetForTesting()
        defer { ClaudeCLIRateLimitGate.resetForTesting() }

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

    @Test
    func `cli usage records rate limit without retrying probe`() async throws {
        try await self.withIsolatedRateLimitGate {
            let attempts = AttemptRecorder()
            let fetcher = ClaudeUsageFetcher(
                browserDetection: BrowserDetection(cacheTTL: 0),
                environment: [:],
                dataSource: .cli)

            let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
                _ = await attempts.record(timeout: timeout)
                throw ClaudeStatusProbeError.rateLimited(
                    "Claude CLI usage endpoint is rate limited right now. Please try again later.")
            }

            await #expect(throws: ClaudeStatusProbeError.self) {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }

            let recorded = await attempts.snapshot()
            #expect(recorded.count == 1)
            #expect(recorded.timeouts == [24])
            #expect(ClaudeCLIRateLimitGate.currentBlockedUntil() != nil)
        }
    }

    @Test
    func `cli rate limit gate blocks background and allows user retry`() async throws {
        try await self.withIsolatedRateLimitGate {
            let attempts = AttemptRecorder()
            let fetcher = ClaudeUsageFetcher(
                browserDetection: BrowserDetection(cacheTTL: 0),
                environment: [:],
                dataSource: .cli)

            ClaudeCLIRateLimitGate.recordRateLimit()

            let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
                _ = await attempts.record(timeout: timeout)
                return ClaudeStatusSnapshot(
                    sessionPercentLeft: 80,
                    weeklyPercentLeft: 70,
                    opusPercentLeft: nil,
                    accountEmail: "manual@example.com",
                    accountOrganization: "Manual Org",
                    loginMethod: "cli",
                    primaryResetDescription: nil,
                    secondaryResetDescription: nil,
                    opusResetDescription: nil,
                    rawText: "probe raw")
            }

            await #expect(throws: ClaudeStatusProbeError.self) {
                try await ProviderInteractionContext.$current.withValue(.background) {
                    try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                        try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                            try await fetcher.loadLatestUsage(model: "sonnet")
                        }
                    }
                }
            }
            #expect(await attempts.snapshot().timeouts.isEmpty)
            #expect(ClaudeCLIRateLimitGate.currentBlockedUntil() != nil)

            let snapshot = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }

            let recorded = await attempts.snapshot()
            #expect(recorded.count == 1)
            #expect(snapshot.primary.usedPercent == 20)
            #expect(ClaudeCLIRateLimitGate.currentBlockedUntil() == nil)
        }
    }

    @Test
    func `manual cli rate limit refresh extends existing cooldown`() async throws {
        try await self.withIsolatedRateLimitGate {
            let attempts = AttemptRecorder()
            let fetcher = ClaudeUsageFetcher(
                browserDetection: BrowserDetection(cacheTTL: 0),
                environment: [:],
                dataSource: .cli)

            ClaudeCLIRateLimitGate.recordRateLimit(now: Date().addingTimeInterval(-295))
            let originalBlockedUntil = try #require(ClaudeCLIRateLimitGate.currentBlockedUntil())

            let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
                _ = await attempts.record(timeout: timeout)
                throw ClaudeStatusProbeError.rateLimited(
                    "Claude CLI usage endpoint is rate limited right now. Please try again later.")
            }

            await #expect(throws: ClaudeStatusProbeError.self) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                        try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                            try await fetcher.loadLatestUsage(model: "sonnet")
                        }
                    }
                }
            }

            let recorded = await attempts.snapshot()
            let refreshedBlockedUntil = try #require(ClaudeCLIRateLimitGate.currentBlockedUntil())
            #expect(recorded.count == 1)
            #expect(refreshedBlockedUntil > originalBlockedUntil.addingTimeInterval(250))
        }
    }

    @Test
    func `usage command configured CLI source bypasses background cooldown`() async throws {
        try await self.withIsolatedRateLimitGate {
            let attempts = AttemptRecorder()
            ClaudeCLIRateLimitGate.recordRateLimit()

            let browserDetection = BrowserDetection(cacheTTL: 0)
            let command = UsageCommandContext(
                format: .json,
                includeCredits: true,
                sourceModeOverride: nil,
                antigravityPlanDebug: false,
                augmentDebug: false,
                webDebugDumpHTML: false,
                webTimeout: 60,
                verbose: false,
                useColor: false,
                resetStyle: .absolute,
                jsonOnly: true,
                includeAllCodexAccounts: false,
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: ClaudeUsageFetcher(
                    browserDetection: browserDetection,
                    environment: [:]),
                browserDetection: browserDetection)
            let tokenContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: CodexBarConfig(providers: [ProviderConfig(id: .claude, source: .cli)]),
                verbose: false)

            let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, timeout, _ in
                _ = await attempts.record(timeout: timeout)
                return ClaudeStatusSnapshot(
                    sessionPercentLeft: 80,
                    weeklyPercentLeft: 70,
                    opusPercentLeft: nil,
                    accountEmail: "configured-cli@example.com",
                    accountOrganization: "Configured CLI Org",
                    loginMethod: "cli",
                    primaryResetDescription: nil,
                    secondaryResetDescription: nil,
                    opusResetDescription: nil,
                    rawText: "probe raw")
            }

            let output = await ProviderInteractionContext.$current.withValue(.background) {
                await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
                    await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                        await CodexBarCLI.fetchUsageOutputs(
                            provider: .claude,
                            status: nil,
                            tokenContext: tokenContext,
                            command: command)
                    }
                }
            }

            let recorded = await attempts.snapshot()
            #expect(recorded.count == 1)
            #expect(output.exitCode == .success)
            #expect(ClaudeCLIRateLimitGate.currentBlockedUntil() == nil)
        }
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
