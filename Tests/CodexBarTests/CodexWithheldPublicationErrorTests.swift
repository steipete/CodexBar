import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `withheld weekly reset clears the failure recorded before relaunch`() async throws {
        try await self.withWithheldPublicationFixture { fixture in
            #expect(fixture.snapshotStore.load(for: fixture.accounts).first?.error != nil)

            let reloaded = self.makeCodexWeeklyPublicationStore(
                settings: fixture.settings, suite: fixture.suite, snapshotStore: fixture.snapshotStore)
            #expect(reloaded.codexAccountSnapshots.first?.error != nil)
            self.installContextualCodexProvider(on: reloaded, sourceLabel: "oauth", kind: .oauth) { _ in
                fixture.low
            }
            await reloaded.refreshProvider(.codex, allowDisabled: true)

            try expectWithheldSnapshot(reloaded.snapshots[.codex], matches: fixture.prior)
            #expect(reloaded.errors[.codex] == nil)
            let persisted = try #require(fixture.snapshotStore.load(for: fixture.accounts).first)
            #expect(persisted.error == nil)
            try expectWithheldSnapshot(persisted.snapshot, matches: fixture.prior)
        }
    }

    @Test
    func `withheld success restores first failure suppression and retains a subsequent outage`() async throws {
        try await self.withWithheldPublicationFixture { fixture in
            let script = WithheldPublicationFetchScript(success: fixture.low)
            self.installContextualCodexProvider(on: fixture.store, sourceLabel: "oauth", kind: .oauth) { _ in
                try await script.load()
            }
            await script.setFailing(false)
            await fixture.store.refreshProvider(.codex, allowDisabled: true)
            #expect(fixture.store.errors[.codex] == nil)
            #expect(fixture.store.failureGates[.codex]?.streak == 0)
            try expectWithheldSnapshot(fixture.store.snapshots[.codex], matches: fixture.prior)

            await script.setFailing(true)
            await fixture.store.refreshProvider(.codex, allowDisabled: true)
            #expect(fixture.store.errors[.codex] == nil)
            await fixture.store.refreshProvider(.codex, allowDisabled: true)
            #expect(fixture.store.errors[.codex] != nil)
            #expect(fixture.store.failureGates[.codex]?.streak == 2)
            let persisted = try #require(fixture.snapshotStore.load(for: fixture.accounts).first)
            try expectWithheldSnapshot(persisted.snapshot, matches: fixture.prior)
        }
    }

    @Test
    func `a withheld publication clears only a connectivity claim`() {
        #expect(UsageStore.shouldPreserveCodexAccountSnapshotOnFailure(
            "Network error: The Internet connection appears to be offline."))
        #expect(UsageStore.shouldPreserveCodexAccountSnapshotOnFailure("Request timed out"))
        #expect(!UsageStore.shouldPreserveCodexAccountSnapshotOnFailure("prior error"))
        #expect(!UsageStore.shouldPreserveCodexAccountSnapshotOnFailure("401 unauthorized"))
        #expect(!UsageStore.shouldPreserveCodexAccountSnapshotOnFailure("Workspace deactivated"))
    }

    @Test(arguments: ["401 unauthorized", "Workspace deactivated", "Could not parse usage", "prior error"])
    func `withheld success preserves nonconnectivity errors`(message: String) async throws {
        try await self.withWithheldPublicationFixture { fixture in
            let row = try #require(fixture.snapshotStore.load(for: fixture.accounts).first)
            fixture.snapshotStore.store([CodexAccountUsageSnapshot(
                account: row.account,
                snapshot: row.snapshot,
                error: message,
                sourceLabel: row.sourceLabel,
                credits: row.credits)])
            fixture.store.errors[.codex] = message
            self.installContextualCodexProvider(on: fixture.store, sourceLabel: "oauth", kind: .oauth) { _ in
                fixture.low
            }
            await fixture.store.refreshProvider(.codex, allowDisabled: true)

            #expect(fixture.store.errors[.codex] == message)
            #expect(fixture.snapshotStore.load(for: fixture.accounts).first?.error == message)
            try expectWithheldSnapshot(fixture.store.snapshots[.codex], matches: fixture.prior)
        }
    }

    @Test
    func `withheld PAT success cannot clear an OAuth account outage`() async throws {
        try await self.withWithheldPublicationFixture { fixture in
            self.installContextualCodexProvider(on: fixture.store, sourceLabel: "pat", kind: .apiToken) { _ in
                fixture.low
            }
            await fixture.store.refreshProvider(.codex, allowDisabled: true)
            #expect(fixture.store.errors[.codex] == fixture.error)
            #expect(fixture.store.failureGates[.codex]?.streak == 2)
            #expect(fixture.snapshotStore.load(for: fixture.accounts).first?.error == fixture.error)
        }
    }

    @Test(arguments: WithheldPublicationInterruption.allCases)
    func `interrupted withheld refresh cannot clear current owner state`(
        interruption: WithheldPublicationInterruption) async throws
    {
        try await self.withWithheldPublicationFixture { fixture in
            let confirmation: SequencedCodexSnapshotLoadStep = switch interruption {
            case .failedConfirmation:
                .failure("Network error: confirmation failed", gated: true)
            case .mismatchedConfirmation:
                .success(self.codexWeeklySnapshot(
                    email: "another-owner@example.com",
                    weeklyUsedPercent: 0,
                    weeklyReset: fixture.low.secondary?.resetsAt,
                    updatedAt: fixture.low.updatedAt), gated: true)
            default:
                .success(fixture.low, gated: true)
            }
            let loader = SequencedCodexSnapshotLoader(steps: [
                .success(fixture.low),
                confirmation,
            ])
            self.installContextualCodexProvider(on: fixture.store, sourceLabel: "oauth", kind: .oauth) { _ in
                try await loader.load()
            }
            let refresh = Task { await fixture.store.refreshProvider(.codex, allowDisabled: true) }
            #expect(await loader.waitUntilCallCount(2))

            switch interruption {
            case .cancelled:
                refresh.cancel()
            case .superseded:
                fixture.store.invalidateProviderRefreshRequests(.codex)
            case .configChanged:
                fixture.settings.codexUsageDataSource = .cli
            case .accountChanged, .workspaceChanged:
                let email = interruption == .workspaceChanged ? fixture.email : "new-owner@example.com"
                fixture.settings._test_liveSystemCodexAccount = self.liveAccount(
                    email: email,
                    identity: .providerAccount(id: "acct-new-owner"))
                _ = await self.seedCodexWeeklyPublicationState(
                    store: fixture.store,
                    settings: fixture.settings,
                    snapshot: self.codexSnapshot(email: email, usedPercent: 55),
                    error: fixture.error)
            case .failedConfirmation, .mismatchedConfirmation:
                break
            }
            let published = fixture.store.snapshots[.codex]
            let diskBefore = try Data(contentsOf: fixture.snapshotURL)
            let selection = fixture.settings.codexResolvedActiveSource
            await loader.release(call: 2)
            await refresh.value

            #expect(fixture.store.errors[.codex] == fixture.error)
            #expect(fixture.store.failureGates[.codex]?.streak == 2)
            try expectWithheldSnapshot(fixture.store.snapshots[.codex], matches: published)
            #expect(fixture.store.credits == fixture.credits)
            #expect(fixture.store.lastSourceLabels[.codex] == "prior-source")
            #expect(fixture.store.lastFetchAttempts[.codex]?.first?.strategyID == "prior-strategy")
            #expect(fixture.settings.codexResolvedActiveSource == selection)
            #expect(try Data(contentsOf: fixture.snapshotURL) == diskBefore)
        }
    }

    @Test
    func `withheld recovery retains credits and candidate through reload and clears consumer outage`() async throws {
        try await self.withWithheldPublicationFixture { fixture in
            let confirmation = self.codexWeeklySnapshot(
                email: fixture.email,
                weeklyUsedPercent: 0,
                weeklyReset: fixture.low.secondary?.resetsAt,
                updatedAt: fixture.low.updatedAt.addingTimeInterval(1),
                resetCredits: fixture.low.codexResetCredits,
                dataConfidence: .exact)
            let loader = SequencedCodexSnapshotLoader(steps: [.success(fixture.low), .success(confirmation)])
            self.installContextualCodexProvider(on: fixture.store, sourceLabel: "oauth", kind: .oauth) { _ in
                try await loader.load()
            }
            #expect(fixture.store.codexConsumerProjection(surface: .liveCard).userFacingErrors.usage != nil)
            await fixture.store.refreshProvider(.codex, allowDisabled: true)

            let persisted = try #require(fixture.snapshotStore.load(for: fixture.accounts).first)
            #expect(persisted.error == nil)
            try expectWithheldSnapshot(persisted.snapshot, matches: fixture.prior)
            #expect(persisted.credits == fixture.credits)
            #expect(persisted.sourceLabel == "oauth")
            #expect(persisted.account == fixture.accounts.first)
            let candidate = try #require(persisted.weeklyResetCandidate)
            try expectWithheldSnapshot(candidate.snapshot, matches: confirmation)
            #expect(fixture.store.credits == fixture.credits)
            #expect(fixture.store.lastSourceLabels[.codex] == "prior-source")
            #expect(fixture.store.lastFetchAttempts[.codex]?.first?.strategyID == "prior-strategy")
            #expect(fixture.store.codexConsumerProjection(surface: .liveCard).userFacingErrors.usage == nil)

            let reloaded = self.makeCodexWeeklyPublicationStore(
                settings: fixture.settings,
                suite: fixture.suite,
                snapshotStore: fixture.snapshotStore)
            let rehydrated = try #require(reloaded.codexAccountSnapshots.first)
            try expectWithheldSnapshot(rehydrated.snapshot, matches: fixture.prior)
            #expect(rehydrated.credits == fixture.credits)
            #expect(rehydrated.error == nil)
            #expect(rehydrated.weeklyResetCandidate?.createdAt == candidate.createdAt)
            try expectWithheldSnapshot(rehydrated.weeklyResetCandidate?.snapshot, matches: candidate.snapshot)
            self.installContextualCodexProvider(on: reloaded, sourceLabel: "oauth", kind: .oauth) { _ in
                fixture.low
            }
            await reloaded.refreshProvider(.codex, allowDisabled: true)
            try expectWithheldSnapshot(reloaded.snapshots[.codex], matches: fixture.prior)
            #expect(reloaded.credits == fixture.credits)
            #expect(reloaded.codexConsumerProjection(surface: .liveCard).userFacingErrors.usage == nil)
        }
    }

    @Test(arguments: WithheldPublicationLayout.allCases)
    func `withheld recovery preserves sibling records in both account layouts`(
        layout: WithheldPublicationLayout) async throws
    {
        let selectRecoveredAccount = layout != .stackedSibling
        let stacked = layout != .segmented
        let suite = "CodexWithheldPublicationErrorTests-layout-\(layout)"
        let email = "stacked-withheld@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings.codexUsageDataSource = .oauth
        settings.multiAccountMenuLayout = stacked ? .stacked : .segmented
        let root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString)
        let targetHome = root.appendingPathComponent("target")
        let siblingHome = root.appendingPathComponent("sibling")
        let target = try self.makeManagedCodexWeeklyPublicationAccount(
            id: UUID(), email: email, workspaceID: "acct-target", workspaceLabel: "Target", homeURL: targetHome)
        let sibling = try self.makeManagedCodexWeeklyPublicationAccount(
            id: UUID(), email: email, workspaceID: "acct-sibling", workspaceLabel: "Sibling", homeURL: siblingHome)
        let managedURL = try self.makeManagedAccountStoreURL(accounts: [target, sibling])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: managedURL)
            try? FileManager.default.removeItem(at: root)
        }
        settings._test_managedCodexAccountStoreURL = managedURL
        settings.codexActiveSource = .managedAccount(id: selectRecoveredAccount ? target.id : sibling.id)
        let selection = settings.codexActiveSource
        let accounts = settings.codexVisibleAccountProjection.visibleAccounts
        let targetVisible = try #require(accounts.first { $0.workspaceAccountID == "acct-target" })
        let siblingVisible = try #require(accounts.first { $0.workspaceAccountID == "acct-sibling" })
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let boundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let nextBoundary = boundary.addingTimeInterval(7 * 24 * 60 * 60)
        let resetCredits = withheldPublicationResetCredits(capturedAt: now, expiresAt: nextBoundary)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 81,
            weeklyReset: boundary,
            updatedAt: now.addingTimeInterval(-600),
            resetCredits: resetCredits,
            dataConfidence: .exact)
        let low = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0,
            weeklyReset: nextBoundary,
            updatedAt: now,
            resetCredits: resetCredits,
            dataConfidence: .exact)
        let confirmation = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0,
            weeklyReset: nextBoundary,
            updatedAt: now.addingTimeInterval(1),
            resetCredits: resetCredits,
            dataConfidence: .exact)
        let credits = CreditsSnapshot(remaining: 17, events: [], updatedAt: prior.updatedAt)
        let error = "Network error: The Internet connection appears to be offline."
        let rows = accounts.map {
            CodexAccountUsageSnapshot(
                account: $0,
                snapshot: prior,
                error: error,
                sourceLabel: "oauth",
                credits: credits)
        }
        let snapshotURL = root.appendingPathComponent("snapshots.json")
        let snapshotStore = FileCodexAccountUsageSnapshotStore(fileURL: snapshotURL)
        snapshotStore.store(rows)
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite, snapshotStore: snapshotStore)
        _ = await self.seedCodexWeeklyPublicationState(store: store, settings: settings, snapshot: prior, error: error)
        store.credits = credits
        var gate = ConsecutiveFailureGate()
        _ = gate.shouldSurfaceError(onFailureWithPriorData: true)
        _ = gate.shouldSurfaceError(onFailureWithPriorData: true)
        store.failureGates[.codex] = gate
        let targetLoader = SequencedCodexSnapshotLoader(steps: [.success(low), .success(confirmation)])
        let siblingLoader = SequencedCodexSnapshotLoader(steps: [.success(low), .failure("confirmation unavailable")])
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { context in
            if context.env["CODEX_HOME"] == targetHome.path {
                return try await targetLoader.load()
            }
            #expect(context.env["CODEX_HOME"] == siblingHome.path)
            return try await siblingLoader.load()
        }
        await CodexWeeklyResetConfirmation.$observationDateOverride.withValue(now) {
            await store.refreshProvider(.codex, allowDisabled: true)
        }

        #expect(await targetLoader.callCount == 2)
        #expect(await siblingLoader.callCount == (stacked ? 2 : 0))
        let recovered = try #require(store.codexAccountSnapshots.first { $0.id == targetVisible.id })
        let unchanged = try #require(store.codexAccountSnapshots.first { $0.id == siblingVisible.id })
        #expect(recovered.error == nil)
        #expect(unchanged.error == error)
        try expectWithheldSnapshot(recovered.snapshot, matches: prior)
        try expectWithheldSnapshot(unchanged.snapshot, matches: prior)
        #expect(recovered.credits == credits)
        #expect(unchanged.credits == credits)
        #expect(recovered.account == targetVisible)
        #expect(unchanged.account == siblingVisible)
        #expect(recovered.sourceLabel == "oauth")
        #expect(recovered.weeklyResetCandidate?.snapshot.updatedAt == confirmation.updatedAt)
        #expect(store.lastSourceLabels[.codex] == "prior-source")
        #expect(store.lastFetchAttempts[.codex]?.first?.strategyID == "prior-strategy")
        #expect(store.errors[.codex] == (selectRecoveredAccount ? nil : error))
        #expect(store.failureGates[.codex]?.streak == (selectRecoveredAccount ? 0 : 2))
        #expect(settings.codexActiveSource == selection)
        let persisted = snapshotStore.load(for: accounts)
        #expect(persisted.count == 2)
        #expect(persisted.first { $0.id == targetVisible.id }?.error == nil)
        #expect(persisted.first { $0.id == siblingVisible.id }?.error == error)
        #expect(persisted.first { $0.id == targetVisible.id }?.weeklyResetCandidate?.createdAt == now)
        #expect(store.codexConsumerProjection(
            surface: .overrideCard,
            snapshotOverride: recovered.snapshot,
            errorOverride: recovered.error,
            creditsOverride: recovered.credits).userFacingErrors.usage == nil)
    }

    private func withWithheldPublicationFixture(
        _ body: (WithheldPublicationFixture) async throws -> Void) async throws
    {
        let suite = "CodexWithheldPublicationErrorTests-\(UUID().uuidString)"
        let email = "withheld-owner@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-withheld-owner"))
        defer { settings._test_liveSystemCodexAccount = nil }
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let boundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let nextBoundary = boundary.addingTimeInterval(7 * 24 * 60 * 60)
        let resetCredits = withheldPublicationResetCredits(capturedAt: now, expiresAt: nextBoundary)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 81,
            weeklyReset: boundary,
            updatedAt: now.addingTimeInterval(-600),
            resetCredits: resetCredits,
            dataConfidence: .exact)
        let low = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0,
            weeklyReset: nextBoundary,
            updatedAt: now,
            resetCredits: resetCredits,
            dataConfidence: .exact)
        let credits = CreditsSnapshot(remaining: 17, events: [], updatedAt: prior.updatedAt)
        let error = "Network error: The Internet connection appears to be offline."
        let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshotStore = FileCodexAccountUsageSnapshotStore(fileURL: snapshotURL)
        let accounts = settings.codexVisibleAccountProjection.visibleAccounts
        let account = try #require(accounts.first)
        snapshotStore.store([CodexAccountUsageSnapshot(
            account: account, snapshot: prior, error: error, sourceLabel: "oauth", credits: credits)])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite, snapshotStore: snapshotStore)
        _ = await self.seedCodexWeeklyPublicationState(store: store, settings: settings, snapshot: prior, error: error)
        store.credits = credits
        store.lastCreditsSnapshot = credits
        store.lastCreditsSnapshotAccountKey = email
        var gate = ConsecutiveFailureGate()
        _ = gate.shouldSurfaceError(onFailureWithPriorData: true)
        _ = gate.shouldSurfaceError(onFailureWithPriorData: true)
        store.failureGates[.codex] = gate
        try await CodexWeeklyResetConfirmation.$observationDateOverride.withValue(now) {
            try await body(WithheldPublicationFixture(
                suite: suite,
                email: email,
                settings: settings,
                store: store,
                snapshotStore: snapshotStore,
                snapshotURL: snapshotURL,
                accounts: accounts,
                prior: prior,
                low: low,
                credits: credits,
                error: error))
        }
    }
}

enum WithheldPublicationInterruption: CaseIterable {
    case cancelled, superseded, configChanged, accountChanged, workspaceChanged, failedConfirmation,
         mismatchedConfirmation
}

enum WithheldPublicationLayout: CaseIterable {
    case stackedActive, stackedSibling, segmented
}

private func expectWithheldSnapshot(_ actual: UsageSnapshot?, matches expected: UsageSnapshot?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(actual) == encoder.encode(expected))
}

private struct WithheldPublicationFixture: Sendable {
    let suite: String
    let email: String
    let settings: SettingsStore
    let store: UsageStore
    let snapshotStore: FileCodexAccountUsageSnapshotStore
    let snapshotURL: URL
    let accounts: [CodexVisibleAccount]
    let prior: UsageSnapshot
    let low: UsageSnapshot
    let credits: CreditsSnapshot
    let error: String
}

/// Use the OAuth fetcher's message shape and transport code so both network classifiers recognize the outage.
private func withheldPublicationNetworkError() -> Error {
    NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorNotConnectedToInternet,
        userInfo: [
            NSLocalizedDescriptionKey: "Network error: The Internet connection appears to be offline.",
        ])
}

private actor WithheldPublicationFetchScript {
    private var failing = true
    private let success: UsageSnapshot

    init(success: UsageSnapshot) {
        self.success = success
    }

    func setFailing(_ value: Bool) {
        self.failing = value
    }

    func load() throws -> UsageSnapshot {
        if self.failing {
            throw withheldPublicationNetworkError()
        }
        return self.success
    }
}

private func withheldPublicationResetCredits(
    capturedAt: Date,
    expiresAt: Date) -> CodexRateLimitResetCreditsSnapshot
{
    CodexRateLimitResetCreditsSnapshot(
        credits: [CodexRateLimitResetCredit(
            id: "withheld-publication-reset-credit",
            resetType: "codex_rate_limits",
            status: .available,
            grantedAt: capturedAt.addingTimeInterval(-24 * 60 * 60),
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)],
        availableCount: 1,
        updatedAt: capturedAt)
}
