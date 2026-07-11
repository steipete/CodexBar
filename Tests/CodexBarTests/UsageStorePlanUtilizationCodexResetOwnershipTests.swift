import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `codex weekly reset detector derives the active account for default refreshes`() async {
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

        #expect(store.weeklyLimitResetDetectorStates.count == 2)
    }

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

    @MainActor
    @Test
    func `codex weekly reset detector keeps managed ownership across token refreshes`() async {
        let store = Self.makeStore()
        let email = "managed-refresh@example.com"
        let storedAccountID = UUID()
        let observedAt = Date(timeIntervalSince1970: 1_700_200_000)
        let beforeRefresh = Self.codexVisibleAccount(
            id: "managed-before",
            email: email,
            authFingerprint: "fingerprint-before",
            storedAccountID: storedAccountID)
        let afterRefresh = Self.codexVisibleAccount(
            id: "managed-after",
            email: email,
            authFingerprint: "fingerprint-after",
            storedAccountID: storedAccountID)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(email: email, plan: "plus", observedAt: observedAt),
            codexVisibleAccount: beforeRefresh,
            now: observedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: Self.codexWeeklySnapshot(
                email: email,
                plan: "plus",
                observedAt: observedAt.addingTimeInterval(60)),
            codexVisibleAccount: afterRefresh,
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

    private static func codexVisibleAccount(
        id: String,
        email: String,
        workspaceAccountID: String? = nil,
        authFingerprint: String? = nil,
        storedAccountID: UUID? = nil) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email,
            workspaceLabel: nil,
            workspaceAccountID: workspaceAccountID,
            authFingerprint: authFingerprint,
            storedAccountID: storedAccountID,
            selectionSource: storedAccountID.map { .managedAccount(id: $0) } ?? .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
    }
}
