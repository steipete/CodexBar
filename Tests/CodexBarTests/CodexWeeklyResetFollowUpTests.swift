import CodexBarCore
import Foundation
import os.lock
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `idle account reset gets one delayed confirmation after switching away`() async throws {
        let suite = "CodexWeeklyResetFollowUpTests-switch-away"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .fiveMinutes
        settings.codexCookieSource = .off
        settings.multiAccountMenuLayout = .segmented
        let email = "weekly-follow-up@example.com"
        let accountID = UUID()
        let siblingID = UUID()
        let root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString)
        let accountHome = root.appendingPathComponent("candidate")
        let siblingHome = root.appendingPathComponent("sibling")
        let account = try self.makeManagedCodexWeeklyPublicationAccount(
            id: accountID,
            email: email,
            workspaceID: "candidate-workspace",
            workspaceLabel: "Candidate",
            homeURL: accountHome)
        let sibling = try self.makeManagedCodexWeeklyPublicationAccount(
            id: siblingID,
            email: email,
            workspaceID: "sibling-workspace",
            workspaceLabel: "Sibling",
            homeURL: siblingHome)
        let accountStoreURL = try self.makeManagedAccountStoreURL(accounts: [account, sibling])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: accountStoreURL)
            try? FileManager.default.removeItem(at: root)
        }
        settings._test_managedCodexAccountStoreURL = accountStoreURL
        settings.codexActiveSource = .managedAccount(id: accountID)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = OSAllocatedUnfairLock(initialState: now)
        let boundary = now.addingTimeInterval(7 * 24 * 60 * 60)
        func snapshot(_ used: Double, at date: Date) -> UsageSnapshot {
            self.codexWeeklySnapshot(
                email: email,
                weeklyUsedPercent: used,
                weeklyReset: boundary,
                updatedAt: date,
                resetCredits: .init(
                    credits: [.init(
                        id: "available-credit",
                        resetType: "codex_rate_limits",
                        status: .available,
                        grantedAt: now.addingTimeInterval(-3 * 86400),
                        expiresAt: boundary.addingTimeInterval(86400),
                        redeemStartedAt: nil,
                        redeemedAt: nil,
                        title: nil,
                        description: nil)],
                    availableCount: 1,
                    updatedAt: date),
                dataConfidence: .exact)
        }
        let prior = snapshot(5, at: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let siblingUsage = snapshot(42, at: now.addingTimeInterval(-2))
        let initial = snapshot(0, at: now.addingTimeInterval(-1))
        let confirmation = snapshot(0, at: now)
        let repeated = snapshot(0, at: now.addingTimeInterval(1))
        let final = snapshot(0, at: now.addingTimeInterval(60))
        let projection = settings.codexVisibleAccountProjection
        let visibleAccount = try #require(projection.visibleAccounts.first { $0.storedAccountID == accountID })
        let visibleSibling = try #require(projection.visibleAccounts.first { $0.storedAccountID == siblingID })
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [
            .init(account: visibleAccount, snapshot: prior, error: nil, sourceLabel: "oauth"),
            .init(account: visibleSibling, snapshot: siblingUsage, error: nil, sourceLabel: "oauth"),
        ])
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings, suite: suite, snapshotStore: snapshotStore)
        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(initial), .success(confirmation), .success(repeated), .success(final),
        ])
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { context in
            #expect(context.env["CODEX_HOME"] == accountHome.path)
            if clock.withLock({ $0 }) == final.updatedAt {
                #expect(ProviderInteractionContext.current == .background)
            }
            return try await loader.load()
        }
        let gate = CodexWeeklyFollowUpGate()
        let observationDate: @Sendable () -> Date = { clock.withLock { $0 } }
        let sleep: @Sendable (Duration) async throws -> Void = { delay in
            #expect(delay == .seconds(60))
            await gate.wait()
        }
        try await CodexWeeklyResetConfirmation.$observationDateProviderOverride.withValue(observationDate) {
            try await CodexWeeklyResetConfirmation.$followUpSleepOverride.withValue(sleep) {
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await store.refreshProvider(.codex, allowDisabled: true)
                }
                #expect(store.snapshots[.codex]?.secondary?.usedPercent == 5)
                #expect(await loader.callCount == 2)
                #expect(store.codexAccountSnapshots.first { $0.id == visibleAccount.id }?
                    .weeklyResetCandidate?.createdAt == now)
                let followUp = try #require(store.codexWeeklyResetFollowUps[visibleAccount.id])
                await store.refreshProvider(.codex, allowDisabled: true)
                #expect(store.codexWeeklyResetFollowUps.count == 1)
                #expect(store.codexWeeklyResetFollowUps[visibleAccount.id]?.createdAt == now)
                #expect(store.codexAccountSnapshots.first { $0.id == visibleAccount.id }?
                    .weeklyResetCandidate?.createdAt == now)

                settings.codexActiveSource = .managedAccount(id: siblingID)
                _ = store.prepareCodexAccountScopedRefreshIfNeeded()
                store.snapshots[.codex] = siblingUsage
                store.lastKnownResetSnapshots[.codex] = siblingUsage
                clock.withLock { $0 = now.addingTimeInterval(60) }
                await gate.resume()
                await followUp.task.value

                #expect(await loader.callCount == 4)
                #expect(await gate.waitCount == 1)
                #expect(store.codexWeeklyResetFollowUps.isEmpty)
                #expect(store.snapshots[.codex]?.updatedAt == siblingUsage.updatedAt)
                #expect(store.snapshots[.codex]?.secondary?.usedPercent == 42)
                let refreshed = try #require(store.codexAccountSnapshots.first { $0.id == visibleAccount.id })
                #expect(refreshed.snapshot?.updatedAt == final.updatedAt)
                #expect(refreshed.snapshot?.secondary?.usedPercent == 0)
                #expect(refreshed.weeklyResetCandidate == nil)
                #expect(snapshotStore.storedSnapshots.first { $0.id == visibleAccount.id }?
                    .snapshot?.updatedAt == final.updatedAt)
            }
        }
    }

    @Test(arguments: CodexWeeklyFollowUpStop.allCases)
    func `pending weekly confirmation stops when its scope or policy changes`(
        change: CodexWeeklyFollowUpStop) async throws
    {
        let suite = "CodexWeeklyResetFollowUpTests-stop-\(change)"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings.codexUsageDataSource = .oauth
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = OSAllocatedUnfairLock(initialState: now)
        let email = "pending-follow-up@example.com"
        func account(fingerprint: String) -> ObservedSystemCodexAccount {
            ObservedSystemCodexAccount(
                email: email,
                workspaceAccountID: "pending-workspace",
                authFingerprint: fingerprint,
                codexHomePath: CodexCredentialFixtures.root.appendingPathComponent("pending-home").path,
                observedAt: now,
                identity: .providerAccount(id: "pending-workspace"))
        }
        settings._test_liveSystemCodexAccount = account(fingerprint: "original-token-material")
        defer { settings._test_liveSystemCodexAccount = nil }
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let visible = try #require(settings.codexVisibleAccountProjection.visibleAccounts.first)
        let previous = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 5,
            weeklyReset: now.addingTimeInterval(86400),
            updatedAt: now.addingTimeInterval(-86400),
            dataConfidence: .exact)
        let low = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0,
            weeklyReset: now.addingTimeInterval(86400),
            updatedAt: now,
            dataConfidence: .exact)
        let candidate = CodexWeeklyResetPublicationCandidate(firstObservedAt: now, snapshot: low)
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in
            Issue.record("Invalidated follow-up must not fetch")
            return low
        }
        let gate = CodexWeeklyFollowUpGate()
        let observationDate: @Sendable () -> Date = { clock.withLock { $0 } }
        let sleep: @Sendable (Duration) async throws -> Void = { _ in await gate.wait() }
        try await CodexWeeklyResetConfirmation.$observationDateProviderOverride.withValue(observationDate) {
            try await CodexWeeklyResetConfirmation.$followUpSleepOverride.withValue(sleep) {
                store.persistCodexWeeklyResetPublicationCandidate(
                    candidate, expectedGuard: store.freshCodexAccountScopedRefreshGuard(), previousSnapshot: previous)
                let followUp = try #require(store.codexWeeklyResetFollowUps[visible.id])
                switch change {
                case .credentials:
                    settings._test_liveSystemCodexAccount = account(fingerprint: "replacement-token-material")
                case .cli:
                    settings.codexUsageDataSource = .cli
                case .pat:
                    settings.codexUsageDataSource = .pat
                case .disabled:
                    let metadata = ProviderDescriptorRegistry.descriptor(for: .codex).metadata
                    settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: false)
                    store.clearProviderState(.codex)
                case .expired:
                    break
                }
                clock.withLock { $0 = now.addingTimeInterval(change == .expired ? 1801 : 60) }
                await gate.resume()
                await followUp.task.value
                #expect(store.codexWeeklyResetFollowUps.isEmpty)
            }
        }
    }
}

enum CodexWeeklyFollowUpStop: CaseIterable, Sendable {
    case credentials, cli, pat, disabled, expired
}

private actor CodexWeeklyFollowUpGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waitCount = 0

    func wait() async {
        self.waitCount += 1
        if self.released { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.resume() }
        }
    }

    func resume() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}
