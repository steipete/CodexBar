import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test(arguments: [false, true], [0.0, 14.0])
    func `normal usage publication retains a dashboard hidden balance until a newer successful read`(
        hasCap: Bool,
        recoveredBalance: Double) async throws
    {
        let fixture = await self.makeExtraUsagePublicationFixture()
        let store = fixture.store
        let hiddenAt = fixture.now.addingTimeInterval(-60)
        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: fixture.email,
                accountID: "shared-workspace",
                codeReviewRemainingPercent: nil,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                creditsAvailable: true,
                codexCreditLimit: self.extraUsagePublicationCap(hasCap: hasCap, updatedAt: hiddenAt),
                updatedAt: hiddenAt),
            targetEmail: fixture.email)

        #expect(store.openAIDashboardAttachmentAuthorized)
        #expect(store.credits?.remaining == 1234)
        #expect(store.snapshots[.codex]?.providerCost?.balanceIsUnavailable == true)
        #expect(store.lastKnownResetSnapshots[.codex]?.providerCost?.balance == 1234)

        let deferred = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: fixture.now,
            codexCreditLimit: self.extraUsagePublicationCap(hasCap: hasCap, updatedAt: fixture.now),
            balanceReadSucceeded: false)
        let usage = self.extraUsagePublicationSnapshot(
            email: fixture.email,
            updatedAt: fixture.now,
            credits: deferred)
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { context in
            #expect(!context.includeCredits)
            return usage
        }
        await store.refreshProvider(.codex, allowDisabled: true)

        let published = try #require(store.snapshots[.codex])
        let display = try #require(CodexExtraUsageCost.creditsForDisplay(
            store.credits,
            attached: published.providerCost))
        let projection = store.codexConsumerProjection(surface: .menuBar, now: fixture.now)
        #expect(published.updatedAt == fixture.now)
        #expect(published.providerCost?.balanceIsUnavailable == true)
        #expect(published.providerCost?.balanceUpdatedAt == hiddenAt)
        #expect(published.providerCost?.balance == nil)
        #expect(published.providerCost?.limit == (hasCap ? 400 : 0))
        #expect(display.balanceReadSucceeded == false)
        #expect(display.displayRemaining == (hasCap ? 100 : nil))
        #expect(projection.extraUsageCost?.balance == nil)
        #expect(store.credits?.remaining == 1234)
        #expect(store.codexAccountSnapshots.first?.snapshot?.providerCost == published.providerCost)

        let recoveredAt = fixture.now.addingTimeInterval(60)
        let recovered = self.extraUsagePublicationSnapshot(
            email: fixture.email,
            updatedAt: recoveredAt,
            credits: CreditsSnapshot(remaining: recoveredBalance, events: [], updatedAt: recoveredAt))
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in recovered }
        await store.refreshProvider(.codex, allowDisabled: true)

        let recoveredCost = try #require(store.snapshots[.codex]?.providerCost)
        let recoveredDisplay = try #require(CodexExtraUsageCost.creditsForDisplay(
            store.credits,
            attached: recoveredCost))
        #expect(recoveredCost.balanceIsUnavailable == nil)
        #expect(recoveredCost.balanceUpdatedAt == recoveredAt)
        #expect(recoveredCost.balance == (recoveredBalance > 0 ? recoveredBalance : nil))
        #expect(recoveredDisplay.balanceReadSucceeded)
        #expect(recoveredDisplay.remaining == recoveredBalance)
        #expect(recoveredDisplay.hasWorkspaceBalance == false)
    }

    @Test(arguments: [false, true])
    func `normal usage publication does not carry extra usage across workspace members`(hidden: Bool) async throws {
        let fixture = await self.makeExtraUsagePublicationFixture()
        let store = fixture.store
        if hidden {
            store.snapshots[.codex] = self.extraUsagePublicationSnapshot(
                email: fixture.email,
                updatedAt: fixture.now.addingTimeInterval(-60),
                credits: CreditsSnapshot(
                    remaining: 0,
                    events: [],
                    updatedAt: fixture.now.addingTimeInterval(-60),
                    balanceReadSucceeded: false,
                    creditsAvailable: true))
        }
        fixture.settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "other-member@example.com",
            identity: .providerAccount(id: "shared-workspace"))
        let usage = self.extraUsagePublicationSnapshot(
            email: "other-member@example.com",
            updatedAt: fixture.now,
            credits: nil)
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in usage }
        await store.refreshProvider(.codex, allowDisabled: true)

        let published = try #require(store.snapshots[.codex])
        #expect(published.accountEmail(for: .codex) == "other-member@example.com")
        #expect(published.providerCost == nil)
        #expect(store.credits == nil)
    }

    @Test(arguments: ["missing guard", "unresolved identity", "other provider", "full credit response"])
    func `extra usage preservation requires a resolved codex publication owner`(scenario: String) async {
        let fixture = await self.makeExtraUsagePublicationFixture()
        let store = fixture.store
        let expectedGuard: CodexAccountScopedRefreshGuard?
        if scenario == "unresolved identity" {
            expectedGuard = CodexAccountScopedRefreshGuard(
                source: .liveSystem,
                identity: .unresolved,
                accountKey: nil)
            store.lastCodexUsagePublicationGuard = expectedGuard
        } else {
            expectedGuard = scenario == "missing guard" ? nil : store.lastCodexUsagePublicationGuard
        }
        let current = self.extraUsagePublicationSnapshot(email: fixture.email, updatedAt: fixture.now, credits: nil)
        let result = store.preservingCodexCost(
            in: current,
            for: scenario == "other provider" ? .claude : .codex,
            owner: expectedGuard,
            includesCredits: scenario == "full credit response")

        #expect(result.providerCost == nil)
    }

    private func makeExtraUsagePublicationFixture() async -> (
        store: UsageStore,
        settings: SettingsStore,
        email: String,
        now: Date)
    {
        let suite = "CodexExtraUsagePublicationTests"
        let email = "balance-member@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "shared-workspace"))
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: RecordingCodexAccountUsageSnapshotStore(initialSnapshots: []))
        store._test_widgetSnapshotSaveOverride = { _ in }
        let now = Date()
        let credits = CreditsSnapshot(
            remaining: 1234,
            events: [],
            updatedAt: now.addingTimeInterval(-120),
            balanceIsWorkspace: true)
        _ = await self.seedCodexWeeklyPublicationState(
            store: store,
            settings: settings,
            snapshot: self.extraUsagePublicationSnapshot(email: email, updatedAt: credits.updatedAt, credits: credits),
            error: nil)
        store.credits = credits
        store.lastCreditsSnapshot = credits
        store.lastCreditsSnapshotOwnerGuard = store.lastCodexUsagePublicationGuard
        store.lastCreditsSnapshotAccountKey = email
        store.lastCreditsSource = .api
        return (store, settings, email, now)
    }

    private func extraUsagePublicationSnapshot(
        email: String,
        updatedAt: Date,
        credits: CreditsSnapshot?) -> UsageSnapshot
    {
        CodexExtraUsageCost.attaching(
            to: self.codexWeeklySnapshot(
                email: email,
                weeklyUsedPercent: 40,
                weeklyReset: updatedAt.addingTimeInterval(2 * 24 * 60 * 60),
                updatedAt: updatedAt),
            credits: credits)
    }

    private func extraUsagePublicationCap(hasCap: Bool, updatedAt: Date) -> CodexCreditLimitSnapshot? {
        hasCap ? CodexCreditLimitSnapshot(
            used: 300,
            limit: 400,
            remainingPercent: 25,
            resetsAt: nil,
            updatedAt: updatedAt) : nil
    }
}
