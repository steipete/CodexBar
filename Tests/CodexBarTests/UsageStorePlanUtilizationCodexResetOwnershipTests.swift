import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `codex weekly reset detector does not derive an owner for default refreshes`() async {
        let store = Self.makeStore()
        let email = "shared-default@example.com"
        let observedAt = Date(timeIntervalSince1970: 1_700_050_000)
        defer { store.settings._test_liveSystemCodexAccount = nil }

        store.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: email,
            authFingerprint: "fingerprint-a",
            codexHomePath: "/tmp/codex-a",
            observedAt: observedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(email: email, plan: "plus", observedAt: observedAt),
            now: observedAt)

        store.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: email,
            authFingerprint: "fingerprint-b",
            codexHomePath: "/tmp/codex-b",
            observedAt: observedAt.addingTimeInterval(60))
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "plus",
                observedAt: observedAt.addingTimeInterval(60)),
            now: observedAt.addingTimeInterval(60))

        #expect(store.weeklyLimitResetDetectorStates.isEmpty)
    }

    @MainActor
    @Test
    func `codex weekly reset detector separates workspace accounts and ignores plan changes`() async throws {
        let store = Self.makeStore()
        let email = "shared-workspace@example.com"
        let ownerA = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "account-a"),
            accountEmail: email))
        let ownerB = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "account-b"),
            accountEmail: email))
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(email: email, plan: "plus", observedAt: observedAt),
            codexLimitResetOwnerKey: ownerA,
            now: observedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "pro",
                observedAt: observedAt.addingTimeInterval(60)),
            codexLimitResetOwnerKey: ownerA,
            now: observedAt.addingTimeInterval(60))
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "plus",
                observedAt: observedAt.addingTimeInterval(120)),
            codexLimitResetOwnerKey: ownerB,
            now: observedAt.addingTimeInterval(120))

        #expect(store.weeklyLimitResetDetectorStates.count == 2)
    }

    @MainActor
    @Test
    func `codex weekly reset detector fails closed without workspace ids`() async {
        let store = Self.makeStore()
        let email = "shared-auth@example.com"
        let observedAt = Date(timeIntervalSince1970: 1_700_100_000)

        #expect(CodexLimitResetOwnerKey(identity: .emailOnly(normalizedEmail: email), accountEmail: email) == nil)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(email: email, plan: "plus", observedAt: observedAt),
            now: observedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "plus",
                observedAt: observedAt.addingTimeInterval(60)),
            now: observedAt.addingTimeInterval(60))

        #expect(store.weeklyLimitResetDetectorStates.isEmpty)
    }

    @MainActor
    @Test
    func `codex weekly reset detector keeps workspace ownership across token refreshes`() async throws {
        let store = Self.makeStore()
        let email = "managed-refresh@example.com"
        let observedAt = Date(timeIntervalSince1970: 1_700_200_000)
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "managed-workspace"),
            accountEmail: email))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(email: email, plan: "plus", observedAt: observedAt),
            codexLimitResetOwnerKey: ownerKey,
            now: observedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "plus",
                observedAt: observedAt.addingTimeInterval(60)),
            codexLimitResetOwnerKey: ownerKey,
            now: observedAt.addingTimeInterval(60))

        #expect(store.weeklyLimitResetDetectorStates.count == 1)
    }

    private static func codexWeeklySnapshot(
        email: String,
        plan: String,
        observedAt: Date) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: observedAt.addingTimeInterval(5 * 3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 80,
                windowMinutes: 10080,
                resetsAt: observedAt.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: observedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: plan))
    }
}
