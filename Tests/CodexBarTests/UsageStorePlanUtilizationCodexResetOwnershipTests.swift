import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `codex weekly reset detector separates workspace accounts and ignores plan changes`() async {
        let store = Self.makeStore()
        let email = "shared-workspace@example.com"
        let workspaceA = Self.codexVisibleAccount(
            id: "workspace-a",
            email: email,
            workspaceAccountID: "account-a")
        let workspaceB = Self.codexVisibleAccount(
            id: "workspace-b",
            email: email,
            workspaceAccountID: "account-b")
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(email: email, plan: "plus", observedAt: observedAt),
            codexVisibleAccount: workspaceA,
            now: observedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "pro",
                observedAt: observedAt.addingTimeInterval(60)),
            codexVisibleAccount: workspaceA,
            now: observedAt.addingTimeInterval(60))
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "plus",
                observedAt: observedAt.addingTimeInterval(120)),
            codexVisibleAccount: workspaceB,
            now: observedAt.addingTimeInterval(120))

        #expect(store.weeklyLimitResetDetectorStates.count == 2)
    }

    @MainActor
    @Test
    func `codex weekly reset detector separates auth fingerprints without workspace ids`() async {
        let store = Self.makeStore()
        let email = "shared-auth@example.com"
        let accountA = Self.codexVisibleAccount(id: "auth-a", email: email, authFingerprint: "fingerprint-a")
        let accountB = Self.codexVisibleAccount(id: "auth-b", email: email, authFingerprint: "fingerprint-b")
        let observedAt = Date(timeIntervalSince1970: 1_700_100_000)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(email: email, plan: "plus", observedAt: observedAt),
            codexVisibleAccount: accountA,
            now: observedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "plus",
                observedAt: observedAt.addingTimeInterval(60)),
            codexVisibleAccount: accountB,
            now: observedAt.addingTimeInterval(60))

        #expect(store.weeklyLimitResetDetectorStates.count == 2)
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

    private static func codexVisibleAccount(
        id: String,
        email: String,
        workspaceAccountID: String? = nil,
        authFingerprint: String? = nil) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email,
            workspaceLabel: nil,
            workspaceAccountID: workspaceAccountID,
            authFingerprint: authFingerprint,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
    }
}
