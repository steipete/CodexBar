import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeActiveAccountIdentityInvalidationTests {
    @Test
    func `ambient identity change clears stale state when a transient fetch fails`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .cli,
                    outcome: Self.transientFailureOutcome())
            }
            await self.persistIdentity("account-a", in: fixture)

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    resetSnapshot: fixture.store.lastKnownResetSnapshots[.claude],
                    tokenSnapshot: fixture.store.tokenSnapshot(for: .claude),
                    error: fixture.store.error(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }

            #expect(result.snapshot == nil)
            #expect(result.resetSnapshot == nil)
            #expect(result.tokenSnapshot == nil)
            #expect(result.error != nil)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-b"))
        }
    }

    @Test
    func `stable ambient identity preserves cached state on a transient fetch failure`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .cli,
                    outcome: Self.transientFailureOutcome())
            }
            await self.persistIdentity("account-a", in: fixture)

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-a") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    resetSnapshot: fixture.store.lastKnownResetSnapshots[.claude],
                    tokenSnapshot: fixture.store.tokenSnapshot(for: .claude),
                    error: fixture.store.error(for: .claude))
            }

            #expect(result.snapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.resetSnapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.tokenSnapshot != nil)
            #expect(result.error == nil)
        }
    }

    @Test
    func `ambient identity change removes old reset backfill before publishing success`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let freshSnapshot = Self.freshSnapshot()
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .auto,
                    outcome: Self.successOutcome(freshSnapshot))
            }
            await self.persistIdentity("account-a", in: fixture)

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    resetSnapshot: fixture.store.lastKnownResetSnapshots[.claude],
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }

            #expect(result.snapshot?.updatedAt == freshSnapshot.updatedAt)
            #expect(result.snapshot?.primary?.resetsAt == nil)
            #expect(result.snapshot?.accountEmail(for: .claude) == "new@example.com")
            #expect(result.resetSnapshot?.updatedAt == freshSnapshot.updatedAt)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-b"))
        }
    }

    @Test
    func `missing active identity does not masquerade as an account switch`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .cli,
                    outcome: Self.transientFailureOutcome())
            }
            await self.persistIdentity("account-a", in: fixture)

            await UsageStore.withActiveClaudeAccountUuidForTesting(nil) {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }

            #expect(result.snapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-a"))
        }
    }

    @Test
    func `first nonnil identity observation seeds without invalidating cached state`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .cli,
                    outcome: Self.transientFailureOutcome())
            }
            let identities = ClaudeIdentitySequence([nil, "account-b"])

            await UsageStore.withActiveClaudeAccountUuidResolverForTesting(
                { identities.next() },
                {
                    await fixture.store.refreshProvider(.claude)
                })

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }

            #expect(result.snapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-b"))
        }
    }

    @Test
    func `identity switch during fetch invalidates an otherwise cacheable transient failure`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .cli,
                    outcome: Self.transientFailureOutcome())
            }
            await self.persistIdentity("account-a", in: fixture)
            let identities = ClaudeIdentitySequence(["account-a", "account-b"])

            await UsageStore.withActiveClaudeAccountUuidResolverForTesting(
                { identities.next() },
                {
                    await fixture.store.refreshProvider(.claude)
                })

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    resetSnapshot: fixture.store.lastKnownResetSnapshots[.claude],
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }

            #expect(result.snapshot == nil)
            #expect(result.resetSnapshot == nil)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-b"))
        }
    }

    @Test
    func `identity switch during successful fetch discards stale result and publishes replacement`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let staleInFlightSnapshot = Self.freshSnapshot()
            let replacementSnapshot = Self.replacementSnapshot()
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .cli,
                    outcome: Self.successOutcome(staleInFlightSnapshot))
            }
            await self.persistIdentity("account-a", in: fixture)
            let identities = ClaudeIdentitySequence(["account-a", "account-b", "account-b", "account-b"])
            let outcomes = ClaudeReplacementFetchSequence(
                first: Self.successOutcome(staleInFlightSnapshot),
                replacement: Self.successOutcome(replacementSnapshot))
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in await outcomes.next() }
            }

            await UsageStore.withActiveClaudeAccountUuidResolverForTesting(
                { identities.next() },
                {
                    let completion = ClaudeRefreshCompletionFlag()
                    let firstRefresh = Task { @MainActor in
                        await fixture.store.refreshProvider(.claude)
                        await completion.markCompleted()
                    }
                    let replacementStarted = await self.waitForReplacementStart(outcomes)
                    #expect(replacementStarted)
                    #expect(await !(completion.isCompleted()))

                    let retiredSnapshot = await MainActor.run { fixture.store.snapshot(for: .claude) }
                    #expect(retiredSnapshot == nil)

                    await outcomes.releaseReplacement()
                    let replacementPublished = await self.waitForSnapshot(
                        replacementSnapshot.updatedAt,
                        in: fixture.store)
                    #expect(replacementPublished)
                    await firstRefresh.value
                    #expect(await completion.isCompleted())
                })

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }
            #expect(result.snapshot?.updatedAt == replacementSnapshot.updatedAt)
            #expect(result.snapshot?.accountEmail(for: .claude) == "replacement@example.com")
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-b"))
        }
    }

    @Test
    func `identity disappearance during successful CLI fetch discards stale result and rechecks`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let staleInFlightSnapshot = Self.freshSnapshot()
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .cli,
                    outcome: Self.successOutcome(staleInFlightSnapshot))
            }
            await self.persistIdentity("account-a", in: fixture)
            let identities = ClaudeIdentitySequence(["account-a", nil, nil, nil])
            let outcomes = ClaudeReplacementFetchSequence(
                first: Self.successOutcome(staleInFlightSnapshot),
                replacement: Self.transientFailureOutcome())
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in await outcomes.next() }
            }

            await UsageStore.withActiveClaudeAccountUuidResolverForTesting(
                { identities.next() },
                {
                    let firstRefresh = Task { @MainActor in
                        await fixture.store.refreshProvider(.claude)
                    }
                    #expect(await self.waitForReplacementStart(outcomes))
                    #expect(await MainActor.run { fixture.store.snapshot(for: .claude) } == nil)

                    await outcomes.releaseReplacement()
                    #expect(await self.waitForError(in: fixture.store))
                    await firstRefresh.value
                })

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }
            #expect(result.snapshot == nil)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-a"))
        }
    }

    @Test
    func `Auto CLI to Web transition cannot backfill prior account resets`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let freshSnapshot = Self.freshSnapshot()
            let fixture = try await MainActor.run {
                let fixture = try self.makeFixture(
                    source: .auto,
                    outcome: Self.successOutcome(
                        freshSnapshot,
                        sourceLabel: "web",
                        strategyKind: .web))
                fixture.store.lastSourceLabels[.claude] = "claude"
                return fixture
            }

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-a") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run { fixture.store.snapshot(for: .claude) }
            #expect(result?.updatedAt == freshSnapshot.updatedAt)
            #expect(result?.primary?.resetsAt == nil)
            #expect(result?.accountEmail(for: .claude) == "new@example.com")
        }
    }

    @Test
    func `Auto Web to CLI transition cannot backfill prior account resets`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let freshSnapshot = Self.freshSnapshot()
            let fixture = try await MainActor.run {
                let fixture = try self.makeFixture(
                    source: .auto,
                    outcome: Self.successOutcome(freshSnapshot))
                fixture.store.lastSourceLabels[.claude] = "web"
                return fixture
            }

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-a") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run { fixture.store.snapshot(for: .claude) }
            #expect(result?.updatedAt == freshSnapshot.updatedAt)
            #expect(result?.primary?.resetsAt == nil)
            #expect(result?.accountEmail(for: .claude) == "new@example.com")
        }
    }

    @Test
    func `ambient CLI identity change does not retire cached Web result when Web refresh fails`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                let fixture = try self.makeFixture(
                    source: .auto,
                    outcome: Self.transientFailureOutcome())
                fixture.store.lastSourceLabels[.claude] = "web"
                return fixture
            }
            await self.persistIdentity("account-a", in: fixture)

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }
            #expect(result.snapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-a"))
        }
    }

    @Test(arguments: [
        (ClaudeUsageDataSource.cli, "web"),
        (.web, "claude"),
        (.api, "oauth"),
    ])
    func `failed explicit Claude authority transition retires prior live state`(
        source: ClaudeUsageDataSource,
        priorSourceLabel: String) async throws
    {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                let fixture = try self.makeFixture(
                    source: source,
                    outcome: Self.transientFailureOutcome())
                fixture.store.lastSourceLabels[.claude] = priorSourceLabel
                return fixture
            }

            await fixture.store.refreshProvider(.claude)

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    resetSnapshot: fixture.store.lastKnownResetSnapshots[.claude],
                    tokenSnapshot: fixture.store.tokenSnapshot(for: .claude),
                    error: fixture.store.error(for: .claude))
            }
            #expect(result.snapshot == nil)
            #expect(result.resetSnapshot == nil)
            #expect(result.tokenSnapshot == nil)
            #expect(result.error != nil)
        }
    }

    @Test
    func `failed Auto refresh preserves prior state because winning authority is unknown`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                let fixture = try self.makeFixture(
                    source: .auto,
                    outcome: Self.transientFailureOutcome())
                fixture.store.lastSourceLabels[.claude] = "admin-api"
                return fixture
            }

            await fixture.store.refreshProvider(.claude)

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    resetSnapshot: fixture.store.lastKnownResetSnapshots[.claude],
                    tokenSnapshot: fixture.store.tokenSnapshot(for: .claude),
                    error: fixture.store.error(for: .claude))
            }
            #expect(result.snapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.resetSnapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.tokenSnapshot != nil)
            #expect(result.error == nil)
        }
    }

    @Test
    func `failed selected OAuth authority transition preserves configured account cache`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let fixture = try await MainActor.run {
                let fixture = try self.makeFixture(
                    source: .auto,
                    outcome: Self.transientFailureOutcome())
                fixture.settings.addTokenAccount(
                    provider: .claude,
                    label: "Saved OAuth",
                    token: "Bearer sk-ant-oat-saved-token")
                let account = try #require(fixture.settings.selectedTokenAccount(for: .claude))
                fixture.store.cacheTokenAccountSnapshot(
                    provider: .claude,
                    account: account,
                    snapshot: fixture.priorSnapshot,
                    sourceLabel: "admin-api")
                return fixture
            }

            await fixture.store.refreshProvider(.claude)

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    resetSnapshot: fixture.store.lastKnownResetSnapshots[.claude],
                    tokenSnapshot: fixture.store.tokenSnapshot(for: .claude),
                    cached: fixture.store.accountSnapshots[.claude],
                    error: fixture.store.error(for: .claude))
            }
            #expect(result.snapshot == nil)
            #expect(result.resetSnapshot == nil)
            #expect(result.tokenSnapshot == nil)
            #expect(result.cached?.count == 1)
            #expect(result.cached?.first?.snapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.error != nil)
        }
    }

    @Test
    func `configured token account cache survives ambient account and credentials file noise`() async throws {
        try await self.withMissingCredentialsFile { credentialsURL in
            let fixture = try await MainActor.run {
                let fixture = try self.makeFixture(
                    source: .cli,
                    outcome: Self.transientFailureOutcome())
                fixture.settings.addTokenAccount(
                    provider: .claude,
                    label: "Saved OAuth",
                    token: "Bearer sk-ant-oat-saved-token")
                let account = try #require(fixture.settings.selectedTokenAccount(for: .claude))
                fixture.store.cacheTokenAccountSnapshot(
                    provider: .claude,
                    account: account,
                    snapshot: fixture.priorSnapshot,
                    sourceLabel: "oauth")
                return fixture
            }
            await self.persistIdentity("account-a", in: fixture)
            let identities = ClaudeIdentitySequence(["account-a", "account-b"])
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in
                    try? FileManager.default.createDirectory(
                        at: credentialsURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? Data("changed".utf8).write(to: credentialsURL)
                    return Self.transientFailureOutcome()
                }
            }

            await UsageStore.withActiveClaudeAccountUuidResolverForTesting(
                { identities.next() },
                {
                    await fixture.store.refreshProvider(.claude)
                })

            let result = await MainActor.run {
                (
                    cached: fixture.store.accountSnapshots[.claude],
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey))
            }
            #expect(result.cached?.count == 1)
            #expect(result.cached?.first?.snapshot?.updatedAt == fixture.priorSnapshot.updatedAt)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-a"))
        }
    }

    @Test(arguments: [
        ("claude", "admin-api", ProviderFetchKind.apiToken),
        ("web", "admin-api", .apiToken),
        ("admin-api", "claude", .cli),
        ("admin-api", "web", .web),
        ("oauth", "claude", .cli),
        ("claude", "oauth", .oauth),
        ("admin-api", "oauth", .oauth),
        ("oauth", "admin-api", .apiToken),
    ])
    func `successful Claude authority transition cannot backfill prior resets`(
        priorSourceLabel: String,
        resultSourceLabel: String,
        strategyKind: ProviderFetchKind) async throws
    {
        try await self.withMissingCredentialsFile { _ in
            let freshSnapshot = Self.freshSnapshot()
            let fixture = try await MainActor.run {
                let fixture = try self.makeFixture(
                    source: .auto,
                    outcome: Self.successOutcome(
                        freshSnapshot,
                        sourceLabel: resultSourceLabel,
                        strategyKind: strategyKind))
                fixture.store.lastSourceLabels[.claude] = priorSourceLabel
                return fixture
            }

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-a") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run { fixture.store.snapshot(for: .claude) }
            #expect(result?.updatedAt == freshSnapshot.updatedAt)
            #expect(result?.primary?.resetsAt == nil)
            #expect(result?.accountEmail(for: .claude) == "new@example.com")
        }
    }

    @Test
    func `active account identity follows and scopes Claude config directory`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"oauthAccount":{"accountUuid":"config-account"}}"#.utf8)
            .write(to: root.appendingPathComponent(".config.json"))
        let environment = ["CLAUDE_CONFIG_DIR": root.path]

        let observed = UsageStore._activeClaudeAccountIdentityFromEnvironmentForTesting(environment)

        #expect(observed == UsageStore._activeClaudeAccountIdentityForTesting(
            "config-account",
            environment: environment))
        #expect(observed != UsageStore._activeClaudeAccountIdentityForTesting("config-account"))
    }

    @Test
    func `account and credential probes share fetch environment profile roots`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-profile-roots-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let alternate = root.appendingPathComponent("alternate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"oauthAccount":{"accountUuid":"home-account"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/.config.json"))
        try Data("home".utf8).write(to: home.appendingPathComponent(".claude/.credentials.json"))
        try Data(#"{"oauthAccount":{"accountUuid":"alternate-account"}}"#.utf8)
            .write(to: alternate.appendingPathComponent(".config.json"))
        try Data("alternate".utf8).write(to: alternate.appendingPathComponent(".credentials.json"))

        let homeEnvironment = ["HOME": home.path]
        let alternateEnvironment = [
            "HOME": home.path,
            "CLAUDE_CONFIG_DIR": alternate.path,
        ]
        let homeIdentity = UsageStore._activeClaudeAccountIdentityFromEnvironmentForTesting(homeEnvironment)
        let alternateIdentity = UsageStore._activeClaudeAccountIdentityFromEnvironmentForTesting(alternateEnvironment)
        let homeFingerprint = ClaudeOAuthCredentialsStore
            .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: homeEnvironment)
        let alternateFingerprint = ClaudeOAuthCredentialsStore
            .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: alternateEnvironment)

        #expect(homeIdentity == UsageStore._activeClaudeAccountIdentityForTesting(
            "home-account",
            environment: homeEnvironment))
        #expect(alternateIdentity == UsageStore._activeClaudeAccountIdentityForTesting(
            "alternate-account",
            environment: alternateEnvironment))
        #expect(homeIdentity != alternateIdentity)
        #expect(homeFingerprint?.contains(home.appendingPathComponent(".claude/.credentials.json").path) == true)
        #expect(alternateFingerprint?.contains(alternate.appendingPathComponent(".credentials.json").path) == true)
        #expect(homeFingerprint != alternateFingerprint)
    }

    @Test(arguments: [
        (ClaudeUsageDataSource.auto, false, false, true),
        (.cli, false, true, true),
        (.auto, false, true, false),
        (.auto, true, false, false),
        (.web, false, false, false),
        (.api, false, false, false),
        (.oauth, false, false, false),
    ])
    func `only ambient Claude sources track CLI identity`(
        source: ClaudeUsageDataSource,
        hasSelectedTokenAccount: Bool,
        hasAdminAPIKey: Bool,
        expected: Bool)
    {
        #expect(UsageStore.shouldTrackClaudeActiveAccountIdentity(
            provider: .claude,
            dataSource: source,
            hasSelectedTokenAccount: hasSelectedTokenAccount,
            hasAdminAPIKey: hasAdminAPIKey) == expected)
    }

    private func withMissingCredentialsFile<T>(
        _ operation: (URL) async throws -> T) async throws -> T
    {
        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            let missingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("missing-credentials.json")
            return try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingURL) {
                try await operation(missingURL)
            }
        }
    }

    @MainActor
    private func makeFixture(
        source: ClaudeUsageDataSource,
        outcome: ProviderFetchOutcome) throws -> ClaudeIdentityFixture
    {
        let settings = testSettingsStore(suiteName: "ClaudeActiveAccountIdentityInvalidationTests")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeUsageDataSource = source
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: provider == .claude)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_providerFetchOutcomeOverride = { _ in outcome }

        let priorSnapshot = Self.priorSnapshot()
        store._setSnapshotForTesting(priorSnapshot, provider: .claude)
        store.lastKnownResetSnapshots[.claude] = priorSnapshot
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4200,
                sessionCostUSD: 1.25,
                last30DaysTokens: 42000,
                last30DaysCostUSD: 12.50,
                daily: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_001)),
            provider: .claude)
        return ClaudeIdentityFixture(
            store: store,
            settings: settings,
            priorSnapshot: priorSnapshot)
    }

    @MainActor
    private func persistIdentity(_ uuid: String, in fixture: ClaudeIdentityFixture) {
        fixture.settings.userDefaults.set(
            UsageStore._activeClaudeAccountIdentityForTesting(uuid),
            forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey)
    }

    private static func transientFailureOutcome() -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .failure(ClaudeStatusProbeError.timedOut),
            attempts: [ProviderFetchAttempt(
                strategyID: "test.cli-timeout",
                kind: .cli,
                wasAvailable: true,
                errorDescription: ClaudeStatusProbeError.timedOut.localizedDescription)])
    }

    private static func successOutcome(
        _ snapshot: UsageSnapshot,
        sourceLabel: String = "CLI",
        strategyKind: ProviderFetchKind = .cli) -> ProviderFetchOutcome
    {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: sourceLabel,
                strategyID: "test.cli-success",
                strategyKind: strategyKind)),
            attempts: [ProviderFetchAttempt(
                strategyID: "test.cli-success",
                kind: .cli,
                wasAvailable: true,
                errorDescription: nil)])
    }

    private static func priorSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_900_000_000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "old@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    private static func freshSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "new@example.com",
                accountOrganization: nil,
                loginMethod: "Max"))
    }

    private static func replacementSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 30,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_200),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "replacement@example.com",
                accountOrganization: nil,
                loginMethod: "Max"))
    }

    private func waitForReplacementStart(_ outcomes: ClaudeReplacementFetchSequence) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await outcomes.replacementStarted() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForSnapshot(_ updatedAt: Date, in store: UsageStore) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await MainActor.run(body: { store.snapshot(for: .claude)?.updatedAt == updatedAt }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForError(in store: UsageStore) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await MainActor.run(body: { store.error(for: .claude) != nil }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@MainActor
private struct ClaudeIdentityFixture {
    let store: UsageStore
    let settings: SettingsStore
    let priorSnapshot: UsageSnapshot
}

private final class ClaudeIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String?]
    private var index = 0

    init(_ values: [String?]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next() -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let value = self.values[min(self.index, self.values.count - 1)]
        self.index += 1
        return value
    }
}

private actor ClaudeReplacementFetchSequence {
    private let first: ProviderFetchOutcome
    private let replacement: ProviderFetchOutcome
    private var invocationCount = 0
    private var replacementIsReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(first: ProviderFetchOutcome, replacement: ProviderFetchOutcome) {
        self.first = first
        self.replacement = replacement
    }

    func next() async -> ProviderFetchOutcome {
        self.invocationCount += 1
        guard self.invocationCount > 1 else { return self.first }
        if !self.replacementIsReleased {
            await withCheckedContinuation { continuation in
                self.releaseContinuations.append(continuation)
            }
        }
        return self.replacement
    }

    func replacementStarted() -> Bool {
        self.invocationCount > 1
    }

    func releaseReplacement() {
        self.replacementIsReleased = true
        let continuations = self.releaseContinuations
        self.releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor ClaudeRefreshCompletionFlag {
    private var completed = false

    func markCompleted() {
        self.completed = true
    }

    func isCompleted() -> Bool {
        self.completed
    }
}
