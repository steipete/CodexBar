import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIUsageSpawnThrottleTests {
    private actor AttemptRecorder {
        private var count = 0

        func record() -> Int {
            self.count += 1
            return self.count
        }

        func snapshot() -> Int {
            self.count
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            self.lock.withLock { self.value }
        }

        func advance(by interval: TimeInterval) {
            self.lock.withLock {
                self.value = self.value.addingTimeInterval(interval)
            }
        }
    }

    @Test
    func `background refresh reuses the cached CLI result within the spawn floor`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                let first = try await self.fetch(strategy, context: context, interaction: .background)
                let second = try await self.fetch(strategy, context: context, interaction: .background)

                #expect(await attempts.snapshot() == 1)
                #expect(second.usage.primary?.usedPercent == first.usage.primary?.usedPercent)
                #expect(second.usage.secondary?.usedPercent == first.usage.secondary?.usedPercent)
                #expect(second.usage.updatedAt == first.usage.updatedAt)
            }
        }
    }

    @Test
    func `Auto returns cached CLI usage after OAuth Keychain access is revoked`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment, sourceMode: .auto)
        let attempts = AttemptRecorder()
        let pipeline = ProviderFetchPipeline { _ in [RevokedOAuthStrategy(), strategy] }

        try await self.withGateStack {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    try await ClaudeStatusProbe.$fetchOverride.withValue(
                        self.successfulFetchOverride(attempts: attempts))
                    {
                        _ = try await self.fetch(strategy, context: context, interaction: .userInitiated)
                        let outcome = await ProviderInteractionContext.$current.withValue(.background) {
                            await pipeline.fetch(context: context, provider: .claude)
                        }

                        let result = try outcome.result.get()
                        #expect(result.strategyID == "claude.cli")
                        #expect(result.usage.primary?.usedPercent == 11)
                        #expect(await attempts.snapshot() == 1)
                        #expect(outcome.attempts.map(\.strategyID) == ["claude.oauth-revoked", "claude.cli"])
                    }
                }
            }
        }
    }

    @Test
    func `background refresh respawns the CLI after the spawn floor elapses`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                    let first = try await self.fetch(strategy, context: context, interaction: .background)
                    clock.advance(by: ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1)
                    let second = try await self.fetch(strategy, context: context, interaction: .background)

                    #expect(await attempts.snapshot() == 2)
                    #expect(second.usage.primary?.usedPercent != first.usage.primary?.usedPercent)
                }
            }
        }
    }

    @Test
    func `user initiated refresh always spawns the CLI`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                _ = try await self.fetch(strategy, context: context, interaction: .background)
                _ = try await self.fetch(strategy, context: context, interaction: .userInitiated)

                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    @Test
    func `failed CLI fetches are not cached`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            let attempt = await attempts.record()
            if attempt == 1 {
                throw ExpectedFetchError.failed
            }
            return Self.makeStatusSnapshot(attempt: attempt)
        }

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                await #expect(throws: ExpectedFetchError.self) {
                    try await self.fetch(strategy, context: context, interaction: .userInitiated)
                }
                #expect(await attempts.snapshot() == 1)

                _ = try await self.fetch(strategy, context: context, interaction: .userInitiated)
                #expect(await attempts.snapshot() == 2)

                _ = try await self.fetch(strategy, context: context, interaction: .background)
                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    @Test
    func `account profile change invalidates the cached CLI result`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                _ = try await self.fetch(strategy, context: context, interaction: .background)
                try Data(#"{"oauthAccount":{"accountUuid":"account-b"}}"#.utf8)
                    .write(to: profile.configURL, options: .atomic)
                _ = try await self.fetch(strategy, context: context, interaction: .background)

                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    @Test
    func `owner CLI recovery pass bypasses the cached result`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let recoveryContext = self.makeContext(
            environment: profile.environment,
            claudeOwnerCLIRecoveryOnly: true)
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                _ = try await self.fetch(strategy, context: context, interaction: .background)
                _ = try await self.fetch(strategy, context: recoveryContext, interaction: .background)

                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    @Test
    func `a session reset boundary invalidates the cached CLI result before the spawn floor elapses`() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)
        // The cached session window resets two minutes out — well inside the 15-minute spawn floor.
        let result = Self.makeFetchResult(sessionResetsAt: start.addingTimeInterval(2 * 60))
        let key = ClaudeCLIUsageSpawnThrottle.Key(
            binary: "/bin/echo",
            accountScope: "scope-a",
            useWebExtras: false,
            includePrepaidBalance: false)

        await ClaudeCLIUsageSpawnThrottle.withIsolatedStoreForTesting {
            await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                ClaudeCLIUsageSpawnThrottle.record(result, for: key)
                clock.advance(by: 60)
                #expect(ClaudeCLIUsageSpawnThrottle.cachedResult(for: key) != nil)

                clock.advance(by: 5 * 60)
                #expect(ClaudeCLIUsageSpawnThrottle.cachedResult(for: key) == nil)
            }
        }
    }

    @Test
    func `unidentified profiles are never cached`() async throws {
        let strategy = self.makeStrategy()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-throttle-unidentified-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = self.makeContext(environment: ["CLAUDE_CONFIG_DIR": root.path])
        let attempts = AttemptRecorder()

        try await self.withGateStack {
            try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                _ = try await self.fetch(strategy, context: context, interaction: .background)
                _ = try await self.fetch(strategy, context: context, interaction: .background)

                #expect(await attempts.snapshot() == 2)
            }
        }
    }

    private enum ExpectedFetchError: Error {
        case failed
    }

    private struct RevokedOAuthStrategy: ProviderFetchStrategy {
        let id = "claude.oauth-revoked"
        let kind = ProviderFetchKind.oauth

        func isAvailable(_: ProviderFetchContext) async -> Bool {
            true
        }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            throw ClaudeOAuthCredentialsError.keychainAccessRevoked
        }

        func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
            context.sourceMode == .auto
        }
    }

    private func makeStrategy() -> ClaudeCLIFetchStrategy {
        ClaudeCLIFetchStrategy(
            useWebExtras: false,
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0),
            hasWebFallback: false)
    }

    private func makeContext(
        environment: [String: String],
        sourceMode: ProviderSourceMode = .cli,
        claudeOwnerCLIRecoveryOnly: Bool = false) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: environment),
            browserDetection: browserDetection,
            claudeOwnerCLIRecoveryOnly: claudeOwnerCLIRecoveryOnly)
    }

    private func makeProfile(accountID: String) throws -> (
        root: URL,
        configURL: URL,
        environment: [String: String])
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-throttle-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(".config.json")
        try Data(#"{"oauthAccount":{"accountUuid":"\#(accountID)"}}"#.utf8)
            .write(to: configURL, options: .atomic)
        return (
            root: root,
            configURL: configURL,
            environment: ["CLAUDE_CONFIG_DIR": root.path])
    }

    private func fetch(
        _ strategy: ClaudeCLIFetchStrategy,
        context: ProviderFetchContext,
        interaction: ProviderInteraction) async throws -> ProviderFetchResult
    {
        try await ProviderInteractionContext.$current.withValue(interaction) {
            try await strategy.fetch(context)
        }
    }

    private func successfulFetchOverride(attempts: AttemptRecorder) -> ClaudeStatusProbe.FetchOverride {
        { _, _, _ in
            let attempt = await attempts.record()
            return Self.makeStatusSnapshot(attempt: attempt)
        }
    }

    private static func makeFetchResult(sessionResetsAt: Date?) -> ProviderFetchResult {
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 5 * 60,
                resetsAt: sessionResetsAt,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        return ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "claude",
            strategyID: "claude.cli",
            strategyKind: .cli)
    }

    private static func makeStatusSnapshot(attempt: Int) -> ClaudeStatusSnapshot {
        ClaudeStatusSnapshot(
            sessionPercentLeft: 90 - attempt,
            weeklyPercentLeft: 80 - attempt,
            opusPercentLeft: nil,
            accountEmail: "cli@example.com",
            accountOrganization: "CLI Org",
            loginMethod: "cli",
            primaryResetDescription: nil,
            secondaryResetDescription: nil,
            opusResetDescription: nil,
            rawText: "probe raw")
    }

    private func withGateStack<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        try await ClaudeCLIUsageSpawnThrottle.withIsolatedStoreForTesting {
            try await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
                try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                    try await operation()
                }
            }
        }
    }
}
