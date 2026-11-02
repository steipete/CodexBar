import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIBackgroundAvailabilityTests {
    @Test(arguments: [
        (false, ClaudeStatusProbeError.timedOut, false),
        (true, ClaudeStatusProbeError.timedOut, true),
        (true, ClaudeStatusProbeError.parseFailed("Claude CLI /usage is still loading usage data."), true),
        (true, ClaudeStatusProbeError.authenticationFailed("Synthetic authentication timeout"), false),
    ])
    func `transient failures preserve only established background CLI availability`(
        established: Bool, failure: ClaudeStatusProbeError, remainsAvailable: Bool) async throws
    {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "timeout-account")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        await self.withBackgroundGates(
            keychainDisabled: !established,
            promptMode: .always,
            establishedBinary: established ? "/bin/echo" : nil,
            establishedEnvironment: context.env,
            oauthCredentialsMissing: true)
        {
            #expect(await strategy.isAvailable(context))
            let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in throw failure }
            let error = await #expect(throws: ClaudeStatusProbeError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await strategy.fetch(context)
                }
            }
            #expect(error?.localizedDescription == failure.localizedDescription)
            #expect(await strategy.isAvailable(context) == remainsAvailable)
        }
    }

    @Test
    func `disabled Keychain allows cold background Auto usage without an established marker`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never) {
            #expect(await strategy.isAvailable(context))
        }
    }

    @Test
    func `enabled Keychain rejects cold background Auto usage without an established marker`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        // Credentials are present-but-denied here, not durably absent, so the deadlock-breaker must not fire.
        await self.withBackgroundGates(keychainDisabled: false, promptMode: .always, oauthCredentialsMissing: false) {
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `disabled Keychain allows background Auto after foreground availability is established`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await self.withBackgroundGates(
            keychainDisabled: true,
            promptMode: .never,
            establishedBinary: "/bin/echo",
            establishedEnvironment: context.env)
        {
            #expect(await strategy.isAvailable(context))
        }
    }

    @Test
    func `background Auto CLI keeps prompt policy after foreground availability is established`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .onlyOnUserAction,
            establishedBinary: "/bin/echo",
            establishedEnvironment: context.env)
        {
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `background Auto CLI uses foreground availability with explicit prompt opt in`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .always,
            establishedBinary: "/bin/echo",
            establishedEnvironment: context.env)
        {
            #expect(await strategy.isAvailable(context))
        }
    }

    @Test(arguments: ClaudeOAuthKeychainPromptMode.allCases)
    func `background explicit OAuth never reaches interactive CLI`(promptMode: ClaudeOAuthKeychainPromptMode) async {
        let strategy = self.makeStrategy()
        let context = self.makeContext(sourceMode: .oauth)

        await self.withBackgroundGates(keychainDisabled: true, promptMode: promptMode) {
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `failed disabled Keychain exception revokes later background Auto usage`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw ExpectedFetchError.failed
            }

        // Present-but-denied throughout: a revoked marker after a failed fetch is not the same as a
        // durable OAuth absence, so the deadlock-breaker must not fire.
        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never, oauthCredentialsMissing: false) {
            #expect(await strategy.isAvailable(context))
            await #expect(throws: ExpectedFetchError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await strategy.fetch(context)
                }
            }
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `enabled Keychain revocation is not bypassed by the OAuth absence deadlock breaker`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw ExpectedFetchError.failed
            }

        // A revoked marker is a deliberate, already-adjudicated "not available right now" outcome from a
        // failed foreground fetch. It must not be second-guessed by the deadlock-breaker even when OAuth
        // credentials are confirmed durably absent — that escape hatch exists only for profiles that never
        // reached user-initiated status at all, not for ones that tried and failed.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .always,
            establishedBinary: "/bin/echo",
            establishedEnvironment: context.env,
            oauthCredentialsMissing: true)
        {
            #expect(await strategy.isAvailable(context))
            await #expect(throws: ExpectedFetchError.self) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    try await strategy.fetch(context)
                }
            }
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `enabled Keychain does not fall back to the OAuth absence probe for an unidentified profile`()
        async throws
    {
        let strategy = self.makeStrategy()
        // No profile is created here: the config file is verifiably absent, so
        // `ClaudeAccountProfile.identifiedSessionScope` returns nil and `captureMarker` can never produce a
        // marker for this environment — there is nothing to establish, revoke, or bind a background attempt to.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-unidentified-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = self.makeContext(environment: ["CLAUDE_CONFIG_DIR": root.path])

        // `.always` isolates this test to the unidentified-profile gate specifically, rather than
        // incidentally passing because of the separate explicit-opt-in requirement. The deadlock-breaker
        // only exists to unblock a profile CodexBar can identify but has never seen a successful
        // foreground fetch for — it must not fire for a profile with no identity at all, since a failed
        // attempt here could never be recorded as a revocation.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .always,
            oauthCredentialsMissing: true)
        {
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `cancelled disabled Keychain exception keeps later background Auto usage available`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw CancellationError()
            }

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await strategy.isAvailable(context))
                            await #expect(throws: CancellationError.self) {
                                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                                    try await strategy.fetch(context)
                                }
                            }
                            #expect(await strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `user initiated explicit OAuth retains interactive CLI recovery`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext(sourceMode: .oauth)

        await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                #expect(await strategy.isAvailable(context))
            }
        }
    }

    @Test
    func `background Auto availability does not cross config profiles`() async throws {
        let strategy = self.makeStrategy()
        let profileA = try self.makeProfile(accountID: "account-a")
        let profileB = try self.makeProfile(accountID: "account-b")
        defer {
            try? FileManager.default.removeItem(at: profileA.root)
            try? FileManager.default.removeItem(at: profileB.root)
        }
        let contextA = self.makeContext(environment: profileA.environment)
        let contextB = self.makeContext(environment: profileB.environment)

        // Profile B is present-but-denied here (a different account, not a durable OAuth absence), so
        // the deadlock-breaker must not fire for it.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .always,
            establishedBinary: "/bin/echo",
            establishedEnvironment: contextA.env,
            oauthCredentialsMissing: false)
        {
            #expect(await strategy.isAvailable(contextA))
            #expect(await !strategy.isAvailable(contextB))
        }
    }

    @Test
    func `background Auto CLI falls back without an established marker when OAuth absence prompts are allowed`()
        async throws
    {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        // A confirmed absence of CodexBar-readable credentials does not by itself prove the interactive
        // CLI is safe to launch unattended, so the deadlock-breaker still requires the same explicit
        // background opt-in (`.always`) that the pre-existing opaque-child gate requires.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .always,
            oauthCredentialsMissing: true)
        {
            #expect(await strategy.isAvailable(context))
        }
    }

    @Test
    func `background Auto CLI stays blocked without an established marker when OAuth absence prompts are not allowed`()
        async throws
    {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        // Even a durable, confirmed absence of OAuth credentials must not launch the interactive CLI
        // unattended without the user's explicit background opt-in.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .onlyOnUserAction,
            oauthCredentialsMissing: true)
        {
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `background Auto CLI stays blocked without an established marker when OAuth credentials are merely denied`()
        async throws
    {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        // Credentials exist but are transiently unreadable/denied (not a durable absence) — the
        // deadlock-breaker must not fire here, only for a confirmed "credentials not found" signal.
        await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .onlyOnUserAction,
            oauthCredentialsMissing: false)
        {
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `background Auto availability does not cross active account changes`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        // Credentials are present-but-denied once the active account no longer matches the established
        // marker, not durably absent, so the deadlock-breaker must not fire here.
        try await self.withBackgroundGates(
            keychainDisabled: false,
            promptMode: .always,
            establishedBinary: "/bin/echo",
            establishedEnvironment: context.env,
            oauthCredentialsMissing: false)
        {
            #expect(await strategy.isAvailable(context))
            try Data(#"{"oauthAccount":{"accountUuid":"account-b"}}"#.utf8)
                .write(to: profile.configURL, options: .atomic)
            #expect(await !strategy.isAvailable(context))
            try FileManager.default.removeItem(at: profile.configURL)
            #expect(await !strategy.isAvailable(context))
        }
    }

    @Test
    func `disabled Keychain background Auto retries a failed attempt without waiting for a foreground refresh`()
        async throws
    {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let retryDelay = ClaudeCLIBackgroundAvailability.initialBackgroundRetryDelay

        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never, oauthCredentialsMissing: false) {
            await self.withClock(clock) {
                // Background refreshes work, then one attempt fails while the Mac briefly wakes from sleep
                // without a network connection.
                #expect(await self.fetchUsage(strategy, context: context))
                clock.advance(by: ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1)
                #expect(await !self.fetchUsage(strategy, context: context, failure: Self.offlineFailure))

                #expect(await !strategy.isAvailable(context))
                clock.advance(by: retryDelay - 1)
                #expect(await !strategy.isAvailable(context))
                clock.advance(by: 1)
                #expect(await strategy.isAvailable(context))
                #expect(await self.fetchUsage(strategy, context: context))
            }
        }
    }

    @Test
    func `repeated disabled Keychain background failures double the retry delay up to its cap`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))

        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never, oauthCredentialsMissing: false) {
            await self.withClock(clock) {
                var expectedDelay = ClaudeCLIBackgroundAvailability.initialBackgroundRetryDelay
                for _ in 0..<8 {
                    #expect(await !self.fetchUsage(strategy, context: context, failure: Self.offlineFailure))
                    clock.advance(by: expectedDelay - 1)
                    #expect(await !strategy.isAvailable(context))
                    clock.advance(by: 1)
                    #expect(await strategy.isAvailable(context))
                    expectedDelay = min(
                        expectedDelay * 2,
                        ClaudeCLIBackgroundAvailability.maximumBackgroundRetryDelay)
                }
            }
        }
    }

    @Test
    func `a successful disabled Keychain background retry resets the retry delay`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let retryDelay = ClaudeCLIBackgroundAvailability.initialBackgroundRetryDelay

        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never, oauthCredentialsMissing: false) {
            await self.withClock(clock) {
                #expect(await !self.fetchUsage(strategy, context: context, failure: Self.offlineFailure))
                clock.advance(by: retryDelay)
                #expect(await strategy.isAvailable(context))
                #expect(await self.fetchUsage(strategy, context: context))

                clock.advance(by: ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1)
                #expect(await !self.fetchUsage(strategy, context: context, failure: Self.offlineFailure))
                clock.advance(by: retryDelay)
                #expect(await strategy.isAvailable(context))
            }
        }
    }

    @Test
    func `disabled Keychain background authentication failures still wait for a foreground refresh`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let signedOut = ClaudeStatusProbeError.authenticationFailed(
            "Claude CLI token expired. Run `claude login` to refresh.")

        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never, oauthCredentialsMissing: false) {
            await self.withClock(clock) {
                #expect(await !self.fetchUsage(strategy, context: context, failure: signedOut))
                clock.advance(by: 7 * 24 * 60 * 60)
                #expect(await !strategy.isAvailable(context))

                let recovered = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await self.fetchUsage(strategy, context: context)
                }
                #expect(recovered)
                clock.advance(by: ClaudeCLIUsageSpawnThrottle.minimumBackgroundSpawnInterval + 1)
                #expect(await strategy.isAvailable(context))
            }
        }
    }

    @Test
    func `an authentication lockout survives a later non-authentication failure`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let signedOut = ClaudeStatusProbeError.authenticationFailed(
            "Claude CLI token expired. Run `claude login` to refresh.")

        await self.withBackgroundGates(keychainDisabled: true, promptMode: .never, oauthCredentialsMissing: false) {
            await self.withClock(clock) {
                #expect(await !self.fetchUsage(strategy, context: context, failure: signedOut))

                // The user clicks Refresh while offline, so the foreground attempt fails for another reason.
                let refreshed = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await self.fetchUsage(strategy, context: context, failure: Self.offlineFailure)
                }
                #expect(!refreshed)
                clock.advance(by: 7 * 24 * 60 * 60)
                #expect(await !strategy.isAvailable(context))
            }
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

    private enum ExpectedFetchError: Error {
        case failed
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

    /// What the probe reports when `claude` renders "Failed to load usage data" because it has no network.
    private static let offlineFailure = ClaudeStatusProbeError.parseFailed(
        "Claude CLI could not load usage data. Open the CLI and retry `/usage`.")

    /// Runs one CLI usage fetch in the current interaction context and reports whether it succeeded.
    private func fetchUsage(
        _ strategy: ClaudeCLIFetchStrategy,
        context: ProviderFetchContext,
        failure: ClaudeStatusProbeError? = nil) async -> Bool
    {
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            if let failure { throw failure }
            return ClaudeStatusSnapshot(
                sessionPercentLeft: 90,
                weeklyPercentLeft: 80,
                opusPercentLeft: nil,
                accountEmail: "cli@example.com",
                accountOrganization: nil,
                loginMethod: "cli",
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "probe raw")
        }
        do {
            _ = try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                try await strategy.fetch(context)
            }
            return true
        } catch {
            return false
        }
    }

    /// Drives both the availability store and the CLI spawn throttle from one test clock.
    private func withClock<T>(_ clock: TestClock, operation: () async throws -> T) async rethrows -> T {
        try await ClaudeCLIUsageSpawnThrottle.withIsolatedStoreForTesting {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeCLIBackgroundAvailability.withNowOverrideForTesting(clock.now) {
                    try await operation()
                }
            }
        }
    }

    private func makeContext(
        sourceMode: ProviderSourceMode = .auto,
        environment: [String: String] = [:]) -> ProviderFetchContext
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
            browserDetection: browserDetection)
    }

    private func makeProfile(accountID: String) throws -> (
        root: URL,
        configURL: URL,
        environment: [String: String])
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-background-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(".config.json")
        try Data(#"{"oauthAccount":{"accountUuid":"\#(accountID)"}}"#.utf8)
            .write(to: configURL, options: .atomic)
        return (
            root: root,
            configURL: configURL,
            environment: ["CLAUDE_CONFIG_DIR": root.path])
    }

    /// Assembles the gate stack every test in this file needs: an isolated background-availability
    /// store, the Keychain-disable/prompt-policy pair under test, the resolved CLI binary, a background
    /// interaction context, and (optionally) a pre-established marker or a pinned
    /// `directCredentialIsMissing` answer for the OAuth-absence deadlock-breaker.
    /// - Parameter oauthCredentialsMissing: `nil` (the default) leaves `directCredentialIsMissingOverride`
    ///   unset, matching production when no test needs to pin that specific signal.
    private func withBackgroundGates<T>(
        keychainDisabled: Bool,
        promptMode: ClaudeOAuthKeychainPromptMode,
        binary: String = "/bin/echo",
        establishedBinary: String? = nil,
        establishedEnvironment: [String: String]? = nil,
        oauthCredentialsMissing: Bool? = nil,
        operation: () async throws -> T) async rethrows -> T
    {
        try await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            if let establishedBinary {
                ClaudeCLIBackgroundAvailability.establish(
                    binary: establishedBinary,
                    environment: establishedEnvironment ?? [:])
            }
            return try await KeychainAccessGate.withTaskOverrideForTesting(keychainDisabled) {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
                    try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(binary) {
                        try await ProviderInteractionContext.$current.withValue(.background) {
                            try await ClaudeOAuthFetchStrategy.$directCredentialIsMissingOverride
                                .withValue(oauthCredentialsMissing) {
                                    try await operation()
                                }
                        }
                    }
                }
            }
        }
    }
}
