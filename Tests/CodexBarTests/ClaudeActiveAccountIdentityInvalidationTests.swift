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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
            }

            #expect(result.snapshot?.updatedAt == freshSnapshot.updatedAt)
            #expect(result.snapshot?.primary?.resetsAt == nil)
            #expect(result.snapshot?.accountEmail(for: .claude) == "new@example.com")
            #expect(result.resetSnapshot?.updatedAt == freshSnapshot.updatedAt)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-b"))
        }
    }

    @Test
    func `explicit OAuth account switch removes old reset backfill before publishing success`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let freshSnapshot = Self.freshSnapshot()
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .oauth,
                    outcome: Self.successOutcome(
                        freshSnapshot,
                        sourceLabel: "OAuth",
                        strategyKind: .oauth))
            }
            await self.persistIdentity("account-a", in: fixture)
            let outcomes = ClaudeReplacementFetchSequence(
                first: Self.successOutcome(
                    freshSnapshot,
                    sourceLabel: "OAuth",
                    strategyKind: .oauth),
                replacement: Self.successOutcome(freshSnapshot))
            await outcomes.releaseReplacement()
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in await outcomes.next() }
            }

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    resetSnapshot: fixture.store.lastKnownResetSnapshots[.claude],
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
            }

            #expect(result.snapshot?.updatedAt == freshSnapshot.updatedAt)
            #expect(result.snapshot?.primary?.resetsAt == nil)
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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
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
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
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
        let (homeIdentity, alternateIdentity, homeExpected, alternateExpected, homeFingerprint, alternateFingerprint) =
            ClaudeOAuthCredentialsStore
                .withEnvironmentCredentialsURLForTesting {
                    (
                        UsageStore._activeClaudeAccountIdentityFromEnvironmentForTesting(homeEnvironment),
                        UsageStore._activeClaudeAccountIdentityFromEnvironmentForTesting(alternateEnvironment),
                        UsageStore._activeClaudeAccountIdentityForTesting("home-account", environment: homeEnvironment),
                        UsageStore._activeClaudeAccountIdentityForTesting(
                            "alternate-account",
                            environment: alternateEnvironment),
                        ClaudeOAuthCredentialsStore
                            .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: homeEnvironment),
                        ClaudeOAuthCredentialsStore
                            .currentCredentialsFileFingerprintWithoutPromptForAuthGate(
                                environment: alternateEnvironment))
                }

        #expect(homeIdentity == homeExpected)
        #expect(alternateIdentity == alternateExpected)
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
        (.oauth, false, false, true),
        (.oauth, false, true, true),
    ])
    func `Claude sources requiring owner corroboration capture active identity`(
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
        outcome: ProviderFetchOutcome,
        environment: [String: String] = [:]) throws -> ClaudeIdentityFixture
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
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
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
            forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting())
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
        strategyKind: ProviderFetchKind = .cli,
        oauthCredentialOwner: ClaudeOAuthCredentialOwner = .claudeCLI) -> ProviderFetchOutcome
    {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: sourceLabel,
                strategyID: "test.cli-success",
                strategyKind: strategyKind,
                claudeOAuthCredentialOwner: strategyKind == .oauth ? oauthCredentialOwner : nil)),
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

    private static func secondReplacementSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_250),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "second-replacement@example.com",
                accountOrganization: nil,
                loginMethod: "Max"))
    }

    private static func postRewriteOAuthSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_300),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "post-rewrite-oauth@example.com",
                accountOrganization: nil,
                loginMethod: "Max"))
    }

    private func waitForReplacementStart(_ outcomes: ClaudeReplacementFetchSequence) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await outcomes.replacementStarted() {
                return true
            }
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

extension ClaudeActiveAccountIdentityInvalidationTests {
    @Test
    func `active account identity follows and scopes Claude config directory`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"oauthAccount":{"accountUuid":"config-account"}}"#.utf8)
            .write(to: root.appendingPathComponent(".config.json"))
        let environment = ["CLAUDE_CONFIG_DIR": root.path]

        let (observed, expected, defaultIdentity) = ClaudeOAuthCredentialsStore
            .withEnvironmentCredentialsURLForTesting {
                (
                    UsageStore._activeClaudeAccountIdentityFromEnvironmentForTesting(environment),
                    UsageStore._activeClaudeAccountIdentityForTesting(
                        "config-account",
                        environment: environment),
                    UsageStore._activeClaudeAccountIdentityForTesting("config-account"))
            }

        #expect(observed == expected)
        #expect(observed != defaultIdentity)
    }

    @Test
    func `same account identity remains stable when preferred config file appears`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-config-stability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountData = Data(#"{"oauthAccount":{"accountUuid":"stable-account"}}"#.utf8)
        try accountData.write(to: root.appendingPathComponent(".claude.json"))
        let environment = ["CLAUDE_CONFIG_DIR": root.path]

        let (fallbackIdentity, preferredIdentity) = try ClaudeOAuthCredentialsStore
            .withEnvironmentCredentialsURLForTesting {
                let fallbackIdentity = UsageStore._activeClaudeAccountIdentityFromEnvironmentForTesting(environment)
                try accountData.write(to: root.appendingPathComponent(".config.json"))
                return (
                    fallbackIdentity,
                    UsageStore._activeClaudeAccountIdentityFromEnvironmentForTesting(environment))
            }

        #expect(fallbackIdentity == preferredIdentity)
    }

    @Test(arguments: [
        (persistedUuid: "stable-account", preservesCachedState: true),
        (persistedUuid: "other-account", preservesCachedState: false),
    ])
    func `legacy identities migrate only for currently observed account`(
        persistedUuid: String,
        preservesCachedState: Bool) async throws
    {
        try await self.withMissingCredentialsFile { _ in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-config-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fallbackURL = root.appendingPathComponent(".claude.json")
            let preferredURL = root.appendingPathComponent(".config.json")
            let accountData = Data(#"{"oauthAccount":{"accountUuid":"stable-account"}}"#.utf8)
            try accountData.write(to: fallbackURL)
            let environment = ["CLAUDE_CONFIG_DIR": root.path]
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .cli,
                    outcome: Self.transientFailureOutcome(),
                    environment: environment)
            }
            let legacyIdentity = UsageStore._legacyClaudeActiveAccountIdentityForTesting(
                persistedUuid,
                accountConfigURL: fallbackURL)
            await MainActor.run {
                fixture.settings.userDefaults.set(
                    legacyIdentity,
                    forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting(environment: environment))
            }
            try accountData.write(to: preferredURL)

            await fixture.store.refreshProvider(.claude)

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    error: fixture.store.error(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting(environment: environment)))
            }
            #expect((result.snapshot?.updatedAt == fixture.priorSnapshot.updatedAt) == preservesCachedState)
            #expect((result.error == nil) == preservesCachedState)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting(
                "stable-account",
                environment: environment))
        }
    }
}

extension ClaudeActiveAccountIdentityInvalidationTests {
    @Test
    func `selecting another Claude profile does not treat its OAuth account as a switch`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-active-account-profiles-\(UUID().uuidString)", isDirectory: true)
        let environmentA = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("profile-a").path]
        let environmentB = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("profile-b").path]
        let freshSnapshot = Self.freshSnapshot()

        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            try await ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
                let fixture = try await MainActor.run {
                    try self.makeFixture(
                        source: .oauth,
                        outcome: Self.successOutcome(
                            freshSnapshot,
                            sourceLabel: "OAuth",
                            strategyKind: .oauth),
                        environment: environmentB)
                }
                let outcomes = ClaudeReplacementFetchSequence(
                    first: Self.successOutcome(
                        freshSnapshot,
                        sourceLabel: "OAuth",
                        strategyKind: .oauth),
                    replacement: Self.transientFailureOutcome())
                await outcomes.releaseReplacement()
                await MainActor.run {
                    fixture.settings.userDefaults.set(
                        UsageStore._activeClaudeAccountIdentityForTesting("account-a", environment: environmentA),
                        forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey)
                    fixture.store._test_providerFetchOutcomeOverride = { _ in await outcomes.next() }
                }

                await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                    await fixture.store.refreshProvider(.claude)
                }

                let result = await MainActor.run {
                    (
                        snapshot: fixture.store.snapshot(for: .claude),
                        legacyIdentity: fixture.settings.userDefaults.string(
                            forKey: UsageStore.claudeActiveAccountIdentityDefaultsKey),
                        profileBIdentity: fixture.settings.userDefaults.string(
                            forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting(
                                environment: environmentB)))
                }
                #expect(result.snapshot?.updatedAt == freshSnapshot.updatedAt)
                #expect(await !outcomes.replacementStarted())
                #expect(result.legacyIdentity == UsageStore._activeClaudeAccountIdentityForTesting(
                    "account-a",
                    environment: environmentA))
                #expect(result.profileBIdentity == UsageStore._activeClaudeAccountIdentityForTesting(
                    "account-b",
                    environment: environmentB))
            }
        }
    }

    @Test
    func `failed owner CLI recovery does not bless the switched account identity`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let staleOAuthSnapshot = Self.freshSnapshot()
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .auto,
                    outcome: Self.successOutcome(
                        staleOAuthSnapshot,
                        sourceLabel: "OAuth",
                        strategyKind: .oauth))
            }
            await self.persistIdentity("account-a", in: fixture)
            let outcomes = ClaudeReplacementFetchSequence(
                first: Self.successOutcome(
                    staleOAuthSnapshot,
                    sourceLabel: "OAuth",
                    strategyKind: .oauth),
                replacement: Self.transientFailureOutcome())
            await outcomes.releaseReplacement()
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in await outcomes.next() }
            }

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    error: fixture.store.error(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
            }
            #expect(result.snapshot == nil)
            #expect(result.error != nil)
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-a"))
        }
    }

    @Test
    func `environment OAuth remains authoritative across a local account switch`() async throws {
        try await self.withMissingCredentialsFile { _ in
            let environmentOAuthSnapshot = Self.freshSnapshot()
            let ownerCLISnapshot = Self.replacementSnapshot()
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .oauth,
                    outcome: Self.successOutcome(
                        environmentOAuthSnapshot,
                        sourceLabel: "OAuth",
                        strategyKind: .oauth,
                        oauthCredentialOwner: .environment))
            }
            await self.persistIdentity("account-a", in: fixture)
            let outcomes = ClaudeReplacementFetchSequence(
                first: Self.successOutcome(
                    environmentOAuthSnapshot,
                    sourceLabel: "OAuth",
                    strategyKind: .oauth,
                    oauthCredentialOwner: .environment),
                replacement: Self.successOutcome(ownerCLISnapshot))
            await outcomes.releaseReplacement()
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in await outcomes.next() }
            }

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                await fixture.store.refreshProvider(.claude)
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
            }
            #expect(result.snapshot?.updatedAt == environmentOAuthSnapshot.updatedAt)
            #expect(result.snapshot?.accountEmail(for: .claude) == "new@example.com")
            #expect(await !outcomes.replacementStarted())
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-b"))
        }
    }

    @Test
    func `pre fetch account switch rejects stale OAuth and publishes owner CLI replacement`() async throws {
        try await self.withMissingCredentialsFile { credentialsURL in
            try FileManager.default.createDirectory(
                at: credentialsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("stale-account-a-credentials".utf8).write(to: credentialsURL)
            let staleOAuthSnapshot = Self.freshSnapshot()
            let replacementSnapshot = Self.replacementSnapshot()
            let fixture = try await MainActor.run {
                try self.makeFixture(
                    source: .auto,
                    outcome: Self.successOutcome(
                        staleOAuthSnapshot,
                        sourceLabel: "OAuth",
                        strategyKind: .oauth))
            }
            await self.persistIdentity("account-a", in: fixture)
            let outcomes = ClaudeReplacementFetchSequence(
                first: Self.successOutcome(
                    staleOAuthSnapshot,
                    sourceLabel: "OAuth",
                    strategyKind: .oauth),
                replacement: Self.successOutcome(replacementSnapshot))
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in await outcomes.next() }
            }

            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                let completion = ClaudeRefreshCompletionFlag()
                let refresh = Task { @MainActor in
                    await fixture.store.refreshProvider(.claude)
                    await completion.markCompleted()
                }
                #expect(await self.waitForReplacementStart(outcomes))
                #expect(await !(completion.isCompleted()))
                #expect(await MainActor.run { fixture.store.snapshot(for: .claude) } == nil)

                await outcomes.releaseReplacement()
                #expect(await self.waitForSnapshot(replacementSnapshot.updatedAt, in: fixture.store))
                await refresh.value
                #expect(await completion.isCompleted())
            }

            let result = await MainActor.run {
                (
                    snapshot: fixture.store.snapshot(for: .claude),
                    persistedIdentity: fixture.settings.userDefaults.string(
                        forKey: UsageStore._claudeActiveAccountIdentityDefaultsKeyForTesting()))
            }
            #expect(result.snapshot?.updatedAt == replacementSnapshot.updatedAt)
            #expect(result.snapshot?.accountEmail(for: .claude) == "replacement@example.com")
            #expect(result.persistedIdentity == UsageStore._activeClaudeAccountIdentityForTesting("account-b"))

            #expect(ClaudeOAuthCredentialsStore.isCurrentCredentialsFileQuarantinedForOAuth())

            let secondReplacementSnapshot = Self.secondReplacementSnapshot()
            let secondOutcomes = ClaudeReplacementFetchSequence(
                first: Self.successOutcome(
                    staleOAuthSnapshot,
                    sourceLabel: "OAuth",
                    strategyKind: .oauth),
                replacement: Self.successOutcome(secondReplacementSnapshot))
            await secondOutcomes.releaseReplacement()
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in await secondOutcomes.next() }
            }
            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                await fixture.store.refreshProvider(.claude)
            }
            #expect(await secondOutcomes.replacementStarted())
            #expect(await MainActor.run {
                fixture.store.snapshot(for: .claude)?.updatedAt == secondReplacementSnapshot.updatedAt
            })

            try Data("rewritten-account-b-credentials-with-a-new-fingerprint".utf8).write(to: credentialsURL)
            let postRewriteOAuthSnapshot = Self.postRewriteOAuthSnapshot()
            let postRewriteOutcomes = ClaudeReplacementFetchSequence(
                first: Self.successOutcome(
                    postRewriteOAuthSnapshot,
                    sourceLabel: "OAuth",
                    strategyKind: .oauth),
                replacement: Self.transientFailureOutcome())
            await postRewriteOutcomes.releaseReplacement()
            await MainActor.run {
                fixture.store._test_providerFetchOutcomeOverride = { _ in await postRewriteOutcomes.next() }
            }
            await UsageStore.withActiveClaudeAccountUuidForTesting("account-b") {
                await fixture.store.refreshProvider(.claude)
            }
            #expect(await !postRewriteOutcomes.replacementStarted())
            #expect(!ClaudeOAuthCredentialsStore.isCurrentCredentialsFileQuarantinedForOAuth())
            #expect(await MainActor.run {
                fixture.store.snapshot(for: .claude)?.updatedAt == postRewriteOAuthSnapshot.updatedAt
            })
        }
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
