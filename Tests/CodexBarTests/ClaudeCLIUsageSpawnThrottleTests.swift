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
    func `background refresh does not launch Claude after the session resets without local activity`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)
        let weeklyResetsAt = start.addingTimeInterval(3 * 24 * 60 * 60)

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                    let key = try #require(self.throttleKey(environment: profile.environment))
                    ClaudeCLIUsageSpawnThrottle.record(
                        Self.makeFetchResult(
                            sessionResetsAt: start.addingTimeInterval(60 * 60),
                            weeklyResetsAt: weeklyResetsAt),
                        for: key)
                    clock.advance(by: 3 * 60 * 60)

                    let result = try await self.fetch(strategy, context: context, interaction: .background)

                    #expect(await attempts.snapshot() == 0)
                    #expect(result.strategyID == "claude.cli")
                    #expect(result.usage.primary?.usedPercent == 0)
                    #expect(result.usage.primary?.resetsAt == nil)
                    #expect(result.usage.primary?.windowMinutes == 5 * 60)
                    #expect(result.usage.secondary?.usedPercent == 25)
                    #expect(result.usage.secondary?.resetsAt == weeklyResetsAt)
                }
            }
        }
    }

    @Test
    func `local Claude activity after the session reset resumes background probing`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let start = Date()
        let clock = TestClock(start)

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                    let key = try #require(self.throttleKey(environment: profile.environment))
                    let sessionResetsAt = start.addingTimeInterval(-60 * 60)
                    ClaudeCLIUsageSpawnThrottle.record(
                        Self.makeFetchResult(sessionResetsAt: sessionResetsAt),
                        for: key)
                    try Self.writeTranscript(
                        in: profile.root,
                        project: "-Users-me-work",
                        modifiedAt: sessionResetsAt.addingTimeInterval(10 * 60))

                    _ = try await self.fetch(strategy, context: context, interaction: .background)

                    #expect(await attempts.snapshot() == 1)
                }
            }
        }
    }

    @Test
    func `owner CLI recovery pass does not launch Claude while no session window is running`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let recoveryContext = self.makeContext(
            environment: profile.environment,
            claudeOwnerCLIRecoveryOnly: true)
        let attempts = AttemptRecorder()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                    let key = try #require(self.throttleKey(environment: profile.environment))
                    ClaudeCLIUsageSpawnThrottle.record(
                        Self.makeFetchResult(sessionResetsAt: start.addingTimeInterval(60)),
                        for: key)
                    clock.advance(by: 60 * 60)

                    let result = try await self.fetch(strategy, context: recoveryContext, interaction: .background)

                    #expect(await attempts.snapshot() == 0)
                    #expect(result.usage.primary?.usedPercent == 0)
                }
            }
        }
    }

    @Test
    func `a failed probe surfaces on idle refreshes without launching Claude`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            let attempt = await attempts.record()
            if attempt == 1 {
                throw ExpectedFetchError.failed
            }
            return Self.makeStatusSnapshot(attempt: attempt)
        }

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                    let key = try #require(self.throttleKey(environment: profile.environment))
                    ClaudeCLIUsageSpawnThrottle.record(
                        Self.makeFetchResult(sessionResetsAt: start.addingTimeInterval(60)),
                        for: key)
                    clock.advance(by: 60 * 60)

                    await #expect(throws: ExpectedFetchError.self) {
                        try await self.fetch(strategy, context: context, interaction: .userInitiated)
                    }
                    // The stored reading is kept, so the background refresh fails without a second launch.
                    await #expect(throws: ExpectedFetchError.self) {
                        try await self.fetch(strategy, context: context, interaction: .background)
                    }
                    #expect(await attempts.snapshot() == 1)

                    // A later successful probe clears the failure.
                    _ = try await self.fetch(strategy, context: context, interaction: .userInitiated)
                    #expect(await attempts.snapshot() == 2)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func `only transient failures from before the reset allow rollover`(authenticationFailed: Bool) async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                    let key = try #require(self.throttleKey(environment: profile.environment))
                    ClaudeCLIUsageSpawnThrottle.record(
                        Self.makeFetchResult(sessionResetsAt: start.addingTimeInterval(30 * 60)),
                        for: key)
                    clock.advance(by: 10 * 60)
                    let error: any Error = authenticationFailed
                        ? ClaudeStatusProbeError.authenticationFailed("Please sign in") : ExpectedFetchError.failed
                    ClaudeCLIUsageSpawnThrottle.recordFailure(error, for: key)
                    clock.advance(by: 60 * 60)

                    if authenticationFailed {
                        await #expect(throws: ClaudeStatusProbeError.self) {
                            try await self.fetch(strategy, context: context, interaction: .background)
                        }
                    } else {
                        let result = try await self.fetch(strategy, context: context, interaction: .background)
                        #expect(result.usage.primary?.usedPercent == 0)
                    }
                    #expect(await attempts.snapshot() == 0)
                }
            }
        }
    }

    @Test
    func `idle state is shared by strategies probing the same CLI account`() async throws {
        let recoveryStrategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let recoveryContext = self.makeContext(
            environment: profile.environment,
            claudeOwnerCLIRecoveryOnly: true)
        let attempts = AttemptRecorder()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                    // The main Auto strategy records with web extras; the recovery strategy probes without them.
                    let mainKey = try #require(ClaudeCLIUsageSpawnThrottle.key(
                        binary: "/bin/echo",
                        environment: profile.environment,
                        useWebExtras: true,
                        includePrepaidBalance: true))
                    ClaudeCLIUsageSpawnThrottle.record(
                        Self.makeFetchResult(sessionResetsAt: start.addingTimeInterval(60)),
                        for: mainKey)
                    clock.advance(by: 60 * 60)

                    let result = try await self.fetch(
                        recoveryStrategy,
                        context: recoveryContext,
                        interaction: .background)

                    #expect(await attempts.snapshot() == 0)
                    #expect(result.usage.primary?.usedPercent == 0)
                }
            }
        }
    }

    @Test
    func `CodexBar probe transcripts do not count as Claude activity`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let since = Date().addingTimeInterval(-60 * 60)
        let probeProject = ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(
            for: ClaudeStatusProbe.dedicatedProbeWorkingDirectoryURL())
        try Self.writeTranscript(in: root, project: probeProject, modifiedAt: Date())
        try Self.writeTranscript(in: root, project: "-Users-me-old", modifiedAt: since.addingTimeInterval(-60))
        let environment = ["CLAUDE_CONFIG_DIR": root.path, "HOME": root.path]

        #expect(!ClaudeLocalSessionActivity.hasActivity(since: since, environment: environment))

        try Self.writeTranscript(in: root, project: "-Users-me-new", modifiedAt: Date(), nested: "subagents")
        #expect(ClaudeLocalSessionActivity.hasActivity(since: since, environment: environment))
    }

    @Test
    func `an unreadable or missing projects root is handled safely`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-activity-\(UUID().uuidString)", isDirectory: true)
        let locked = root.appendingPathComponent("projects/-Users-me-locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let since = Date().addingTimeInterval(-60 * 60)

        #expect(ClaudeLocalSessionActivity.hasActivity(
            since: since,
            in: root.appendingPathComponent("projects", isDirectory: true),
            excludingProjectDirectoryNamed: nil))
        #expect(!ClaudeLocalSessionActivity.hasActivity(
            since: since,
            in: root.appendingPathComponent("missing", isDirectory: true),
            excludingProjectDirectoryNamed: nil))
    }

    @Test
    func `an inaccessible ancestor is not mistaken for a missing projects root`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-activity-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("locked/projects", isDirectory: true)
        let locked = projects.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        #expect(ClaudeLocalSessionActivity.hasActivity(
            since: Date(), in: projects, excludingProjectDirectoryNamed: nil))
    }

    @Test
    func `activity in another profile backup does not resume the selected CLI account`() throws {
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let since = Date().addingTimeInterval(-60 * 60)
        let otherProfile = profile.root.appendingPathComponent(".claude-swap-backup/sessions/2-other")
        try Self.writeTranscript(in: otherProfile, project: "-Users-me-work", modifiedAt: Date())

        #expect(!ClaudeLocalSessionActivity.hasActivity(since: since, environment: profile.environment))
    }

    @Test(arguments: [true, false])
    func `symbolic links never hide local Claude activity`(linksRoot: Bool) throws {
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let shared = profile.root.appendingPathComponent("shared")
        let since = Date().addingTimeInterval(-60 * 60)
        try Self.writeTranscript(in: shared, project: "-Users-me-work", modifiedAt: Date())
        let link = profile.root.appendingPathComponent(linksRoot ? "projects" : "projects/linked-project")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: shared.appendingPathComponent("projects"))

        #expect(ClaudeLocalSessionActivity.hasActivity(since: since, environment: profile.environment))
    }

    @Test
    func `user initiated refresh launches Claude even with no session window running`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let attempts = AttemptRecorder()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start)

        try await self.withGateStack {
            try await ClaudeCLIUsageSpawnThrottle.withNowOverrideForTesting(clock.now) {
                try await ClaudeStatusProbe.$fetchOverride.withValue(self.successfulFetchOverride(attempts: attempts)) {
                    let key = try #require(self.throttleKey(environment: profile.environment))
                    ClaudeCLIUsageSpawnThrottle.record(
                        Self.makeFetchResult(sessionResetsAt: start.addingTimeInterval(60)),
                        for: key)
                    clock.advance(by: 60 * 60)

                    _ = try await self.fetch(strategy, context: context, interaction: .userInitiated)

                    #expect(await attempts.snapshot() == 1)
                }
            }
        }
    }

    @Test
    func `rollover resets every elapsed window and keeps running ones`() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 80,
                windowMinutes: 5 * 60,
                resetsAt: now.addingTimeInterval(-1),
                resetDescription: "Resets 3pm"),
            secondary: RateWindow(
                usedPercent: 60,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(-10),
                resetDescription: "Resets Fri"),
            tertiary: RateWindow(
                usedPercent: 30,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(60),
                resetDescription: "Resets Sat"),
            extraRateWindows: [
                NamedRateWindow(
                    id: "scoped-elapsed",
                    title: "Scoped",
                    window: RateWindow(
                        usedPercent: 45,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: now.addingTimeInterval(-5),
                        resetDescription: "Resets Thu"),
                    usageKnown: true),
                NamedRateWindow(
                    id: "scoped-running",
                    title: "Scoped running",
                    window: RateWindow(
                        usedPercent: 15,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: now.addingTimeInterval(120),
                        resetDescription: "Resets Sun"),
                    usageKnown: true),
            ],
            updatedAt: now.addingTimeInterval(-60 * 60))

        let rolled = ClaudeCLIUsageSpawnThrottle.rollingOverElapsedWindows(in: usage, now: now)

        #expect(rolled.primary?.usedPercent == 0)
        #expect(rolled.primary?.resetsAt == nil)
        #expect(rolled.primary?.resetDescription == nil)
        #expect(rolled.secondary?.usedPercent == 0)
        #expect(rolled.primary?.isSyntheticPlaceholder == false)
        #expect(rolled.tertiary == usage.tertiary)
        #expect(rolled.extraRateWindows?.first?.window.usedPercent == 0)
        #expect(rolled.extraRateWindows?.first?.window.resetsAt == nil)
        #expect(rolled.extraRateWindows?.first?.id == "scoped-elapsed")
        #expect(rolled.extraRateWindows?.last == usage.extraRateWindows?.last)
        #expect(rolled.updatedAt == usage.updatedAt)
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
            environment: ["CLAUDE_CONFIG_DIR": root.path, "HOME": root.path])
    }

    private func throttleKey(environment: [String: String]) -> ClaudeCLIUsageSpawnThrottle.Key? {
        ClaudeCLIUsageSpawnThrottle.key(
            binary: "/bin/echo",
            environment: environment,
            useWebExtras: false,
            includePrepaidBalance: false)
    }

    private static func writeTranscript(
        in configRoot: URL,
        project: String,
        modifiedAt: Date,
        nested: String? = nil) throws
    {
        var directory = configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
        if let nested {
            directory = directory.appendingPathComponent(nested, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
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

    private static func makeFetchResult(sessionResetsAt: Date?, weeklyResetsAt: Date? = nil) -> ProviderFetchResult {
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 5 * 60,
                resetsAt: sessionResetsAt,
                resetDescription: nil),
            secondary: weeklyResetsAt.map {
                RateWindow(usedPercent: 25, windowMinutes: 7 * 24 * 60, resetsAt: $0, resetDescription: nil)
            },
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
