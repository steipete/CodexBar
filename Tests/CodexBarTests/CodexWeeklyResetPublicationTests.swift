import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `single refresh persists provider snapshot for startup confirmation`() async throws {
        let suite = "CodexWeeklyResetPublicationTests-single-startup-hydration"
        let email = "startup-hydrated@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-startup-hydrated"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let priorBoundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let nextBoundary = priorBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 69,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let initialLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.2,
            weeklyReset: nextBoundary,
            updatedAt: now.addingTimeInterval(-40))
        let rebound = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 68,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-20))
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-weekly-round-trip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshotStore = FileCodexAccountUsageSnapshotStore(fileURL: snapshotURL)
        let firstStore = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        self.installContextualCodexProvider(on: firstStore) { _ in prior }

        await firstStore.refreshProvider(.codex, allowDisabled: true)

        let persistedSnapshots = snapshotStore.load(
            for: settings.codexVisibleAccountProjection.visibleAccounts)
        let persisted = try #require(persistedSnapshots.first)
        #expect(persistedSnapshots.count == 1)
        #expect(firstStore.codexAccountSnapshots.count == 1)
        #expect(firstStore.codexAccountSnapshots.first?.id == persisted.id)
        #expect(persisted.account.workspaceAccountID == "acct-startup-hydrated")
        #expect(persisted.account.email == email)
        #expect(persisted.snapshot?.updatedAt == prior.updatedAt)
        #expect(persisted.snapshot?.accountEmail(for: .codex) == email)
        #expect(persisted.sourceLabel == "test-codex")

        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(initialLow),
            .success(rebound, gated: true),
        ])
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.codexAccountSnapshots.first?.snapshot?.updatedAt == prior.updatedAt)
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }
        let recorder = CodexWeeklyPublicationEventRecorder(email: email)
        defer { recorder.invalidate() }

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        #expect(await loader.waitUntilCallCount(2))

        #expect(store.snapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 69)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.lastSourceLabels[.codex] == "test-codex")
        #expect(recorder.usedPercents.isEmpty)

        await loader.release(call: 2)
        await refreshTask.value

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex]?.updatedAt == rebound.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 68)
        #expect(store.lastCodexAccountScopedRefreshGuard?.identity == .providerAccount(id: "acct-startup-hydrated"))
        #expect(recorder.usedPercents.isEmpty)
    }

    @Test
    func `single persistence rejects another member in the same workspace`() async {
        let suite = "CodexWeeklyResetPublicationTests-single-persistence-member-isolation"
        let email = "current-member@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-shared-workspace"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let otherMember = self.codexWeeklySnapshot(
            email: "other-member@example.com",
            weeklyUsedPercent: 42,
            weeklyReset: Date().addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: Date())
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        self.installContextualCodexProvider(on: store) { _ in otherMember }

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.codexAccountSnapshots.isEmpty)
        #expect(snapshotStore.storedSnapshots.isEmpty)
    }

    @Test
    func `single startup rejects hydrated snapshot from another workspace`() async throws {
        let suite = "CodexWeeklyResetPublicationTests-single-startup-workspace-isolation"
        let email = "workspace-isolation@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-current-workspace"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let currentAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts.first)
        let otherWorkspaceAccount = CodexVisibleAccount(
            id: currentAccount.id,
            email: currentAccount.email,
            workspaceLabel: currentAccount.workspaceLabel,
            workspaceAccountID: "acct-other-workspace",
            authFingerprint: currentAccount.authFingerprint,
            storedAccountID: currentAccount.storedAccountID,
            selectionSource: currentAccount.selectionSource,
            isActive: currentAccount.isActive,
            isLive: currentAccount.isLive,
            canReauthenticate: currentAccount.canReauthenticate,
            canRemove: currentAccount.canRemove)
        let now = Date()
        let priorBoundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let otherWorkspacePrior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 71,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let currentSnapshot = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 42,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-20))
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [
            CodexAccountUsageSnapshot(
                account: otherWorkspaceAccount,
                snapshot: otherWorkspacePrior,
                error: nil,
                sourceLabel: "wrong-workspace"),
        ])
        let loader = SequencedCodexSnapshotLoader(steps: [.success(currentSnapshot, gated: true)])
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        #expect(await loader.waitUntilCallCount(1))

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)

        await loader.release(call: 1)
        await refreshTask.value

        #expect(await loader.callCount == 1)
        #expect(store.snapshots[.codex]?.updatedAt == currentSnapshot.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 42)
        let persisted = try #require(snapshotStore.storedSnapshots.first)
        #expect(snapshotStore.storedSnapshots.count == 1)
        #expect(store.codexAccountSnapshots.count == 1)
        #expect(store.codexAccountSnapshots.first?.id == persisted.id)
        #expect(persisted.account.workspaceAccountID == "acct-current-workspace")
        #expect(persisted.account.email == email)
        #expect(persisted.snapshot?.updatedAt == currentSnapshot.updatedAt)
    }

    @Test
    func `single refresh retains the weekly lane when a source omits it`() async {
        let suite = "CodexWeeklyResetPublicationTests-single-missing-weekly"
        let email = "missing-weekly@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-missing-weekly"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let priorBoundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 57,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let partial = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: nil,
            weeklyReset: nil,
            updatedAt: now.addingTimeInterval(-20),
            sessionUsedPercent: 31)
        let loader = SequencedCodexSnapshotLoader(steps: [.success(partial)])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(await loader.callCount == 1)
        #expect(store.snapshots[.codex]?.updatedAt == partial.updatedAt)
        #expect(store.snapshots[.codex]?.primary?.usedPercent == 31)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 57)
        #expect(store.snapshots[.codex]?.secondary?.resetsAt == priorBoundary)
        #expect(store.lastKnownResetSnapshots[.codex]?.secondary?.usedPercent == 57)
    }

    @Test
    func `single refresh keeps prior state private until rebound confirmation publishes`() async {
        let suite = "CodexWeeklyResetPublicationTests-single-gated-rebound"
        let email = "gated-rebound@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-gated-rebound"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let priorBoundary = now.addingTimeInterval(3 * 24 * 60 * 60)
        let nextBoundary = priorBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 64,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let initialLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.2,
            weeklyReset: nextBoundary,
            updatedAt: now.addingTimeInterval(-40))
        let rebound = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 63,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-20))
        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(initialLow),
            .success(rebound, gated: true),
        ])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let priorRevision = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior)
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }
        let recorder = CodexWeeklyPublicationEventRecorder(email: email)
        defer { recorder.invalidate() }

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        #expect(await loader.waitUntilCallCount(2))

        #expect(store.snapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 64)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.lastKnownResetSnapshots[.codex]?.secondary?.usedPercent == 64)
        #expect(store.errors[.codex] == "prior error")
        #expect(store.lastSourceLabels[.codex] == "prior-source")
        #expect(store.lastFetchAttempts[.codex]?.count == 1)
        #expect(store.lastFetchAttempts[.codex]?.first?.strategyID == "prior-strategy")
        #expect(store.lastFetchAttempts[.codex]?.first?.errorDescription == "prior diagnostic")
        #expect(store.planUtilizationHistoryRevision == priorRevision)
        #expect(recorder.usedPercents.isEmpty)

        await loader.release(call: 2)
        await refreshTask.value

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex]?.updatedAt == rebound.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 63)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == rebound.updatedAt)
        #expect(store.lastKnownResetSnapshots[.codex]?.secondary?.usedPercent == 63)
        #expect(store.errors[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == "test-codex")
        #expect(store.lastFetchAttempts[.codex]?.count == 1)
        #expect(store.lastFetchAttempts[.codex]?.first?.strategyID == "contextual-test-codex")
        #expect(recorder.usedPercents.isEmpty)
    }

    @Test
    func `single refresh publishes the second matching low observation only`() async {
        let suite = "CodexWeeklyResetPublicationTests-single-confirmed-low"
        let email = "confirmed-low@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-confirmed-low"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let priorBoundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let nextBoundary = priorBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 72,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let initialLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.2,
            weeklyReset: nextBoundary,
            updatedAt: now.addingTimeInterval(-40))
        let confirmedLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.7,
            weeklyReset: nextBoundary.addingTimeInterval(30),
            updatedAt: now.addingTimeInterval(-20))
        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(initialLow),
            .success(confirmedLow),
        ])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }
        let recorder = CodexWeeklyPublicationEventRecorder(email: email)
        defer { recorder.invalidate() }

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex]?.updatedAt == confirmedLow.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 0.7)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent != initialLow.secondary?.usedPercent)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == confirmedLow.updatedAt)
        #expect(recorder.count == 1)
        #expect(recorder.usedPercents == [0.7])
    }

    @Test(arguments: CodexRejectedConfirmationCase.allCases)
    func `rejected single confirmation preserves every prior public surface`(
        rejection: CodexRejectedConfirmationCase) async
    {
        let suite = "CodexWeeklyResetPublicationTests-rejected-\(rejection.rawValue)"
        let email = "rejected-\(rejection.rawValue)@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-rejected-\(rejection.rawValue)"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let priorBoundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let nextBoundary = priorBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 81,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let initialLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.1,
            weeklyReset: nextBoundary,
            updatedAt: now.addingTimeInterval(-40))
        let confirmationStep: SequencedCodexSnapshotLoadStep = switch rejection {
        case .error:
            .failure("soft confirmation failure")
        case .missingBoundary:
            .success(self.codexWeeklySnapshot(
                email: email,
                weeklyUsedPercent: 0.4,
                weeklyReset: nil,
                updatedAt: now.addingTimeInterval(-20)))
        case .mismatchedBoundary:
            .success(self.codexWeeklySnapshot(
                email: email,
                weeklyUsedPercent: 0.4,
                weeklyReset: nextBoundary.addingTimeInterval(3 * 60),
                updatedAt: now.addingTimeInterval(-20)))
        case .differentMember:
            .success(self.codexWeeklySnapshot(
                email: "another-member@example.com",
                weeklyUsedPercent: 0.4,
                weeklyReset: nextBoundary.addingTimeInterval(30),
                updatedAt: now.addingTimeInterval(-20)))
        }
        let loader = SequencedCodexSnapshotLoader(steps: [.success(initialLow), confirmationStep])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let priorRevision = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }
        let recorder = CodexWeeklyPublicationEventRecorder(email: email)
        defer { recorder.invalidate() }

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 81)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.lastKnownResetSnapshots[.codex]?.secondary?.usedPercent == 81)
        #expect(store.errors[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == "prior-source")
        #expect(store.lastFetchAttempts[.codex]?.count == 1)
        #expect(store.lastFetchAttempts[.codex]?.first?.strategyID == "prior-strategy")
        #expect(store.lastFetchAttempts[.codex]?.first?.errorDescription == "prior diagnostic")
        #expect(store.planUtilizationHistoryRevision == priorRevision)
        #expect(recorder.usedPercents.isEmpty)
    }

    @Test
    func `confirmed reset resists a later stale pre reset observation`() async {
        let suite = "CodexWeeklyResetPublicationTests-post-reset-stale"
        let email = "post-reset-stale@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-post-reset-stale"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let priorBoundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let nextBoundary = priorBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 78,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let initialLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.2,
            weeklyReset: nextBoundary,
            updatedAt: now.addingTimeInterval(-40))
        let confirmedLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.6,
            weeklyReset: nextBoundary.addingTimeInterval(30),
            updatedAt: now.addingTimeInterval(-20))
        let stalePreReset = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 77,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-10))
        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(initialLow),
            .success(confirmedLow),
            .success(stalePreReset),
        ])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }
        let recorder = CodexWeeklyPublicationEventRecorder(email: email)
        defer { recorder.invalidate() }

        await store.refreshProvider(.codex, allowDisabled: true)
        let acceptedRevision = store.planUtilizationHistoryRevision
        #expect(store.snapshots[.codex]?.updatedAt == confirmedLow.updatedAt)
        #expect(recorder.usedPercents == [0.6])

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(await loader.callCount == 3)
        #expect(store.snapshots[.codex]?.updatedAt == confirmedLow.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 0.6)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == confirmedLow.updatedAt)
        #expect(store.planUtilizationHistoryRevision == acceptedRevision)
        #expect(recorder.usedPercents == [0.6])
    }

    @Test
    func `single refresh never compares a prior snapshot across provider owners`() async {
        let suite = "CodexWeeklyResetPublicationTests-owner-transition"
        let email = "owner-transition@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-owner-transition-a"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let now = Date()
        let priorBoundary = now.addingTimeInterval(2 * 24 * 60 * 60)
        let nextBoundary = priorBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let prior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 82,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let newOwnerLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.3,
            weeklyReset: nextBoundary,
            updatedAt: now.addingTimeInterval(-20))
        let confirmedNewOwnerLow = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.6,
            weeklyReset: nextBoundary.addingTimeInterval(30),
            updatedAt: now.addingTimeInterval(-10))
        let loader = SequencedCodexSnapshotLoader(steps: [
            .success(newOwnerLow),
            .success(confirmedNewOwnerLow),
        ])
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: prior,
            error: nil)
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-owner-transition-b"))
        self.installContextualCodexProvider(on: store) { _ in try await loader.load() }
        let recorder = CodexWeeklyPublicationEventRecorder(email: email)
        defer { recorder.invalidate() }

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(await loader.callCount == 2)
        #expect(store.snapshots[.codex]?.updatedAt == confirmedNewOwnerLow.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 0.6)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == confirmedNewOwnerLow.updatedAt)
        #expect(recorder.usedPercents.isEmpty)
    }

    @Test
    func `stacked refresh rejects a response explicitly owned by another member`() async throws {
        let suite = "CodexWeeklyResetPublicationTests-stacked-response-email-mismatch"
        let targetID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let siblingID = try #require(UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-stacked-mismatch-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-stacked-mismatch-sibling-\(UUID().uuidString)", isDirectory: true)
        let target = try self.makeManagedCodexWeeklyPublicationAccount(
            id: targetID,
            email: "target-member@example.com",
            workspaceID: "shared-provider-workspace",
            workspaceLabel: "Target Member",
            homeURL: targetHome)
        let sibling = try self.makeManagedCodexWeeklyPublicationAccount(
            id: siblingID,
            email: "sibling-member@example.com",
            workspaceID: "sibling-provider-workspace",
            workspaceLabel: "Sibling Member",
            homeURL: siblingHome)
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [target, sibling])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        let now = Date()
        let targetMismatch = self.codexWeeklySnapshot(
            email: "another-member@example.com",
            weeklyUsedPercent: 64,
            weeklyReset: now.addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: now)
        let siblingSnapshot = self.codexWeeklySnapshot(
            email: sibling.email,
            weeklyUsedPercent: 22,
            weeklyReset: now.addingTimeInterval(2 * 24 * 60 * 60),
            updatedAt: now)
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return isTarget ? targetMismatch : siblingSnapshot
        }

        await store.refreshCodexVisibleAccountsForMenu()

        #expect(store.snapshots[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains { $0.account.storedAccountID == targetID })
        #expect(store.codexAccountSnapshots.contains { $0.account.storedAccountID == siblingID })
        #expect(!snapshotStore.storedSnapshots.contains { $0.account.storedAccountID == targetID })
        #expect(snapshotStore.storedSnapshots.contains { $0.account.storedAccountID == siblingID })
    }

    @Test
    func `stacked refresh never publishes or persists an unconfirmed account reset`() async throws {
        let suite = "CodexWeeklyResetPublicationTests-stacked"
        let email = "shared-stacked@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings.multiAccountMenuLayout = .stacked

        let suspiciousID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-303030303030"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-313131313131"))
        let suspiciousHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-weekly-suspicious-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-weekly-sibling-\(UUID().uuidString)", isDirectory: true)
        let suspiciousAccount = try self.makeManagedCodexWeeklyPublicationAccount(
            id: suspiciousID,
            email: email,
            workspaceID: "acct-stacked-suspicious",
            workspaceLabel: "Suspicious Workspace",
            homeURL: suspiciousHome)
        let siblingAccount = try self.makeManagedCodexWeeklyPublicationAccount(
            id: siblingID,
            email: email,
            workspaceID: "acct-stacked-sibling",
            workspaceLabel: "Sibling Workspace",
            homeURL: siblingHome)
        let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [suspiciousAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: managedStoreURL)
            try? FileManager.default.removeItem(at: suspiciousHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings.codexActiveSource = .managedAccount(id: suspiciousID)

        let visibleAccounts = settings.codexVisibleAccountProjection.visibleAccounts
        #expect(visibleAccounts.count == 2)
        let suspiciousVisible = try #require(visibleAccounts.first {
            $0.workspaceAccountID == "acct-stacked-suspicious"
        })
        let siblingVisible = try #require(visibleAccounts.first {
            $0.workspaceAccountID == "acct-stacked-sibling"
        })
        let now = Date()
        let priorBoundary = now.addingTimeInterval(3 * 24 * 60 * 60)
        let nextBoundary = priorBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let suspiciousPriorAccount = CodexVisibleAccount(
            id: "prior-email-derived-row",
            email: email,
            workspaceLabel: suspiciousVisible.workspaceLabel,
            workspaceAccountID: suspiciousVisible.workspaceAccountID,
            authFingerprint: "prior-auth-fingerprint",
            storedAccountID: suspiciousVisible.storedAccountID,
            selectionSource: suspiciousVisible.selectionSource,
            isActive: suspiciousVisible.isActive,
            isLive: suspiciousVisible.isLive,
            canReauthenticate: suspiciousVisible.canReauthenticate,
            canRemove: suspiciousVisible.canRemove)
        let suspiciousPrior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 84,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let siblingPrior = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 62,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-60))
        let priorRows = [
            CodexAccountUsageSnapshot(
                account: suspiciousPriorAccount,
                snapshot: suspiciousPrior,
                error: nil,
                sourceLabel: "cached-suspicious"),
            CodexAccountUsageSnapshot(
                account: siblingVisible,
                snapshot: siblingPrior,
                error: nil,
                sourceLabel: "cached-sibling"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorRows)
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        store.codexAccountSnapshots = priorRows
        let priorRevision = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: suspiciousPrior,
            error: nil)

        let suspiciousInitial = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.1,
            weeklyReset: nextBoundary,
            updatedAt: now.addingTimeInterval(-40))
        let suspiciousRejected = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 0.4,
            weeklyReset: nil,
            updatedAt: now.addingTimeInterval(-20))
        let siblingUpdated = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 63,
            weeklyReset: priorBoundary,
            updatedAt: now.addingTimeInterval(-20))
        let suspiciousLoader = SequencedCodexSnapshotLoader(steps: [
            .success(suspiciousInitial),
            .success(suspiciousRejected, gated: true),
        ])
        let siblingLoader = SequencedCodexSnapshotLoader(steps: [.success(siblingUpdated)])
        let suspiciousHomePath = suspiciousHome.path
        let siblingHomePath = siblingHome.path
        self.installContextualCodexProvider(on: store) { context in
            switch context.env["CODEX_HOME"] {
            case suspiciousHomePath:
                try await suspiciousLoader.load()
            case siblingHomePath:
                try await siblingLoader.load()
            default:
                throw TestRefreshError(message: "Unexpected CODEX_HOME routing")
            }
        }
        let currentRecorder = CodexWeeklyPublicationEventRecorder(email: email)
        defer { currentRecorder.invalidate() }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        #expect(await suspiciousLoader.waitUntilCallCount(2))
        #expect(await siblingLoader.waitUntilCompletedCallCount(1))

        try self.expectBlockedStackedResetState(
            store: store,
            snapshotStore: snapshotStore,
            prior: suspiciousPrior,
            historyRevision: priorRevision,
            recorder: currentRecorder)

        await suspiciousLoader.release(call: 2)
        await refreshTask.value

        #expect(await suspiciousLoader.callCount == 2)
        #expect(await siblingLoader.callCount == 1)
        try self.expectFinalStackedResetState(
            store: store,
            snapshotStore: snapshotStore,
            expectation: FinalStackedResetExpectation(
                targetAccount: suspiciousVisible,
                siblingAccount: siblingVisible,
                targetPrior: suspiciousPrior,
                siblingUpdated: siblingUpdated,
                historyRevision: priorRevision),
            recorder: currentRecorder)
    }

    private func expectBlockedStackedResetState(
        store: UsageStore,
        snapshotStore: RecordingCodexAccountUsageSnapshotStore,
        prior: UsageSnapshot,
        historyRevision: Int,
        recorder: CodexWeeklyPublicationEventRecorder) throws
    {
        let target = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-stacked-suspicious"
        })
        #expect(target.snapshot?.updatedAt == prior.updatedAt)
        #expect(target.snapshot?.secondary?.usedPercent == 84)
        #expect(target.sourceLabel == "cached-suspicious")
        #expect(snapshotStore.storedSnapshots.isEmpty)
        #expect(store.snapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 84)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.errors[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == "prior-source")
        #expect(store.lastFetchAttempts[.codex]?.first?.strategyID == "prior-strategy")
        #expect(store.planUtilizationHistoryRevision == historyRevision)
        #expect(recorder.usedPercents.isEmpty)
    }

    private func expectFinalStackedResetState(
        store: UsageStore,
        snapshotStore: RecordingCodexAccountUsageSnapshotStore,
        expectation: FinalStackedResetExpectation,
        recorder: CodexWeeklyPublicationEventRecorder) throws
    {
        let target = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-stacked-suspicious"
        })
        #expect(target.account.id == expectation.targetAccount.id)
        #expect(target.account.email == expectation.targetAccount.email)
        #expect(target.snapshot?.accountEmail(for: .codex) == expectation.targetAccount.email)
        #expect(target.snapshot?.updatedAt == expectation.targetPrior.updatedAt)
        #expect(target.snapshot?.secondary?.usedPercent == 84)
        #expect(target.error == nil)
        #expect(target.sourceLabel == "cached-suspicious")
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-stacked-suspicious"
                && $0.snapshot?.secondary?.usedPercent == 0.1
        })
        let persistedTarget = try #require(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-stacked-suspicious"
        })
        #expect(persistedTarget.snapshot?.updatedAt == expectation.targetPrior.updatedAt)
        #expect(persistedTarget.snapshot?.secondary?.usedPercent == 84)
        #expect(persistedTarget.error == nil)
        #expect(persistedTarget.sourceLabel == "cached-suspicious")
        let sibling = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-stacked-sibling"
        })
        #expect(sibling.snapshot?.updatedAt == expectation.siblingUpdated.updatedAt)
        #expect(sibling.snapshot?.secondary?.usedPercent == 63)
        #expect(snapshotStore.storedSnapshots.count == 2)
        #expect(Set(snapshotStore.storedSnapshots.map(\.id)) == Set([
            expectation.targetAccount.id,
            expectation.siblingAccount.id,
        ]))
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-stacked-suspicious"
                && $0.snapshot?.secondary?.usedPercent == 0.1
        })
        #expect(store.snapshots[.codex]?.updatedAt == expectation.targetPrior.updatedAt)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 84)
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == expectation.targetAccount.email)
        #expect(store.lastKnownResetSnapshots[.codex]?.updatedAt == expectation.targetPrior.updatedAt)
        #expect(
            store.lastKnownResetSnapshots[.codex]?.accountEmail(for: .codex) == expectation.targetAccount.email)
        #expect(store.errors[.codex] == nil)
        #expect(store.lastSourceLabels[.codex] == "prior-source")
        #expect(store.lastFetchAttempts[.codex]?.first?.strategyID == "prior-strategy")
        #expect(store.planUtilizationHistoryRevision == expectation.historyRevision)
        #expect(recorder.usedPercents.isEmpty)
    }
}

private struct FinalStackedResetExpectation {
    let targetAccount: CodexVisibleAccount
    let siblingAccount: CodexVisibleAccount
    let targetPrior: UsageSnapshot
    let siblingUpdated: UsageSnapshot
    let historyRevision: Int
}

enum CodexRejectedConfirmationCase: String, CaseIterable, Sendable {
    case differentMember
    case error
    case missingBoundary
    case mismatchedBoundary
}

private final class CodexWeeklyPublicationEventRecorder: @unchecked Sendable {
    private let email: String
    private let lock = NSLock()
    private var observations: [Double] = []
    private var token: NSObjectProtocol?

    init(email: String) {
        self.email = email
        self.token = NotificationCenter.default.addObserver(
            forName: .codexbarWeeklyLimitReset,
            object: nil,
            queue: nil)
        { [weak self] notification in
            guard let self,
                  let event = notification.object as? WeeklyLimitResetEvent
            else {
                return
            }
            let usedPercent = MainActor.assumeIsolated { () -> Double? in
                guard event.provider == .codex, event.accountLabel == self.email else { return nil }
                return event.usedPercent
            }
            guard let usedPercent else { return }
            self.lock.lock()
            self.observations.append(usedPercent)
            self.lock.unlock()
        }
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.observations.count
    }

    var usedPercents: [Double] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.observations
    }

    func invalidate() {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
        self.token = nil
    }

    deinit {
        self.invalidate()
    }
}
