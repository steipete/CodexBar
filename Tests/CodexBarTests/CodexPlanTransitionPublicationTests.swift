import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexPlanTransitionPublicationTests {
    private let epoch = Int(Date().timeIntervalSince1970) - 30

    @Test
    func `new plan cannot borrow missing weekly usage from the old plan`() async throws {
        let previous = try self.snapshot(plan: "plus", usedPercent: 80, offset: 0, resetOffset: 86400)
        let current = try self.snapshot(plan: "pro", usedPercent: 5, offset: 10, resetOffset: 3600)
            .with(primary: nil, secondary: nil)
        #expect(UsageStore.codexBackfillingResetWindows(current, from: previous).secondary == nil)
        let admission = await UsageStore.codexOutcomeAdmittedForPublication(
            initialOutcome: self.outcome(current),
            previousSnapshot: previous,
            previousSourceLabel: "oauth",
            missingWindowBackfillSnapshot: previous,
            fetchConfirmation: { self.outcome(current) })
        let published = try #require(admission.outcome).result.get().usage
        #expect(published.secondary == nil)
    }

    @Test(arguments: [0, 5], [false, true])
    func `new token plan replaces previous plan quota baseline`(
        usedPercent: Int, missingPrevious: Bool) async throws
    {
        let previous = try self.snapshot(plan: "plus", usedPercent: 80, offset: 0, resetOffset: 86400)
        let current = try self.snapshot(plan: "pro", usedPercent: usedPercent, offset: 10, resetOffset: 3600)
        let confirmation = try self.snapshot(plan: "pro", usedPercent: usedPercent, offset: 20, resetOffset: 3600)
        let admission = await UsageStore.codexOutcomeAdmittedForPublication(
            initialOutcome: self.outcome(current),
            previousSnapshot: missingPrevious ? nil : previous,
            previousSourceLabel: "oauth",
            missingWindowBackfillSnapshot: previous,
            fetchConfirmation: { self.outcome(confirmation) })
        let published = try #require(admission.outcome).result.get().usage
        #expect(published.loginMethod(for: .codex) == "pro")
        #expect(published.secondary?.usedPercent == Double(usedPercent))
        #expect(published.secondary?.resetsAt == current.secondary?.resetsAt)
        #expect(admission.pendingCandidate == nil)
    }

    @Test(arguments: ["plus", " PLUS ", ""])
    func `same or unknown token plan cannot discard previous quota evidence`(plan: String) async throws {
        let previous = try self.snapshot(plan: "plus", usedPercent: 80, offset: 0, resetOffset: 86400)
        let current = try self.snapshot(plan: plan, usedPercent: 0, offset: 10, resetOffset: 3600)
        let admission = await UsageStore.codexOutcomeAdmittedForPublication(
            initialOutcome: self.outcome(current),
            previousSnapshot: previous,
            previousSourceLabel: "oauth",
            missingWindowBackfillSnapshot: previous,
            fetchConfirmation: { self.outcome(current) })
        #expect(admission.outcome == nil)
    }

    @Test(arguments: ["plus", ""], [false, true])
    func `near zero confirmation must retain the initial plan`(plan: String, hasPrevious: Bool) async throws {
        let previous = try self.snapshot(plan: "plus", usedPercent: 80, offset: 0, resetOffset: 86400)
        let initial = try self.snapshot(plan: "pro", usedPercent: 0, offset: 10, resetOffset: 3600)
        let confirmation = try self.snapshot(plan: plan, usedPercent: 0, offset: 20, resetOffset: 3600)
        let admission = await UsageStore.codexOutcomeAdmittedForPublication(
            initialOutcome: self.outcome(initial),
            previousSnapshot: hasPrevious ? previous : nil,
            previousSourceLabel: "oauth",
            missingWindowBackfillSnapshot: hasPrevious ? previous : nil,
            fetchConfirmation: { self.outcome(confirmation) })
        #expect(admission.outcome == nil)
        #expect(admission.pendingCandidate == nil)
    }

    @Test
    func `fresh nonzero confirmation can publish its own plan`() async throws {
        let initial = try self.snapshot(plan: "pro", usedPercent: 0, offset: 10, resetOffset: 3600)
        let confirmation = try self.snapshot(plan: "plus", usedPercent: 5, offset: 20, resetOffset: 3600)
        let admission = await UsageStore.codexOutcomeAdmittedForPublication(
            initialOutcome: self.outcome(initial),
            previousSnapshot: nil,
            previousSourceLabel: nil,
            missingWindowBackfillSnapshot: nil,
            fetchConfirmation: { self.outcome(confirmation) })
        let published = try #require(admission.outcome).result.get().usage
        #expect(published.loginMethod(for: .codex) == "plus")
        #expect(published.secondary?.usedPercent == 5)
    }

    @Test(arguments: [false, true])
    func `older or incomplete new plan cannot discard previous quota evidence`(older: Bool) async throws {
        let previous = try self.snapshot(plan: "plus", usedPercent: 80, offset: 0, resetOffset: 86400)
        let current = try self.snapshot(plan: "pro", usedPercent: 0, offset: older ? -1 : 10, resetOffset: 3600)
            .withDataConfidence(older ? .exact : .unknown)
        let admission = await UsageStore.codexOutcomeAdmittedForPublication(
            initialOutcome: self.outcome(current),
            previousSnapshot: previous,
            previousSourceLabel: "oauth",
            missingWindowBackfillSnapshot: previous,
            fetchConfirmation: { self.outcome(current) })
        #expect(admission.outcome == nil)
    }

    fileprivate func snapshot(plan: String, usedPercent: Int, offset: Int, resetOffset: Int) throws -> UsageSnapshot {
        let epoch = self.epoch
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": "fixture@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
        ]).base64EncodedString()
        let credentials = CodexOAuthCredentials(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            idToken: "fixture.\(payload).signature",
            accountId: "fixture-account",
            lastRefresh: nil)
        let body = """
        {"rate_limit":{"primary_window":{"used_percent":5,"reset_at":\(epoch + 3600),
        "limit_window_seconds":18000},"secondary_window":{"used_percent":\(usedPercent),
        "reset_at":\(epoch + resetOffset),"limit_window_seconds":604800}}}
        """
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(body.utf8))
        let reconciled = try #require(CodexReconciledState.fromOAuth(
            response: response,
            credentials: credentials,
            updatedAt: Date(timeIntervalSince1970: Double(epoch + offset))))
        return reconciled.toUsageSnapshot().withDataConfidence(.exact)
    }

    private func outcome(_ snapshot: UsageSnapshot) -> ProviderFetchOutcome {
        let result = ProviderFetchResult(
            usage: snapshot,
            credits: nil,
            dashboard: nil,
            sourceLabel: "oauth",
            strategyID: "codex.oauth",
            strategyKind: .oauth)
        return ProviderFetchOutcome(result: .success(result), attempts: [])
    }
}

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `subscription upgrade publishes new plan and quota without disabling Codex`() async throws {
        let suite = "CodexPlanTransitionPublicationTests-upgrade"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "fixture@example.com", identity: .providerAccount(id: "fixture-account"))
        defer { settings._test_liveSystemCodexAccount = nil }
        let fixture = CodexPlanTransitionPublicationTests()
        let previous = try fixture.snapshot(plan: "plus", usedPercent: 80, offset: 0, resetOffset: 86400)
        let current = try fixture.snapshot(plan: "pro", usedPercent: 0, offset: 10, resetOffset: 3600)
        let confirmation = try fixture.snapshot(plan: "pro", usedPercent: 0, offset: 20, resetOffset: 3600)
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store, settings: settings, snapshot: previous, error: nil)
        store.lastSourceLabels[.codex] = "oauth"
        let loader = SequencedCodexSnapshotLoader(steps: [.success(current), .success(confirmation)])
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in
            try await loader.load()
        }

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.loginMethod(for: .codex) == "pro")
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 0)
        #expect(store.lastKnownResetSnapshots[.codex]?.loginMethod(for: .codex) == "pro")
        #expect(store.errors[.codex] == nil)
        #expect(await loader.callCount == 2)
    }
}
