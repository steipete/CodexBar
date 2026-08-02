import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension CodexManagedOpenAIWebTests {
    @Test
    func `authorized dashboard merges subscription metadata into existing codex usage`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-subscription-merge")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let updatedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let existingUsage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 18,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: managedAccount.email,
                accountOrganization: nil,
                loginMethod: "Pro"))
        store.snapshots[.codex] = existingUsage
        store.lastSourceLabels[.codex] = "codex-cli"
        let publicationGuard = store.currentCodexAccountScopedRefreshGuard()
        store.lastCodexUsagePublicationGuard = publicationGuard
        store.lastCodexAccountScopedRefreshGuard = publicationGuard

        let renewal = Date(timeIntervalSince1970: 1_787_236_207)
        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: managedAccount.email,
                codeReviewRemainingPercent: 90,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                creditsRemaining: 10,
                accountPlan: "Pro",
                subscriptionRenewsAt: renewal,
                updatedAt: Date()),
            targetEmail: managedAccount.email)

        let mergedUsage = try #require(store.snapshots[.codex])
        #expect(mergedUsage.primary == existingUsage.primary)
        #expect(mergedUsage.secondary == existingUsage.secondary)
        #expect(mergedUsage.updatedAt == existingUsage.updatedAt)
        #expect(mergedUsage.identity?.providerID == existingUsage.identity?.providerID)
        #expect(mergedUsage.identity?.accountEmail == existingUsage.identity?.accountEmail)
        #expect(mergedUsage.identity?.loginMethod == existingUsage.identity?.loginMethod)
        #expect(mergedUsage.subscriptionRenewsAt == renewal)
        #expect(mergedUsage.subscriptionExpiresAt == nil)
        #expect(store.lastSourceLabels[.codex] == "codex-cli")

        let refreshedUsage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 23,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 47,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: updatedAt.addingTimeInterval(60),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: managedAccount.email,
                accountOrganization: nil,
                loginMethod: "Pro"))
        store.snapshots[.codex] = refreshedUsage

        let presentedUsage = try #require(store.presentationSnapshot(for: .codex))
        #expect(presentedUsage.primary == refreshedUsage.primary)
        #expect(presentedUsage.secondary == refreshedUsage.secondary)
        #expect(presentedUsage.updatedAt == refreshedUsage.updatedAt)
        #expect(presentedUsage.subscriptionRenewsAt == renewal)
        #expect(store.snapshots[.codex]?.subscriptionRenewsAt == nil)

        store.snapshots[.codex] = mergedUsage
        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: managedAccount.email,
                codeReviewRemainingPercent: 90,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                creditsRemaining: 10,
                accountPlan: "Pro",
                updatedAt: Date()),
            targetEmail: managedAccount.email)

        let clearedUsage = try #require(store.snapshots[.codex])
        #expect(clearedUsage.subscriptionRenewsAt == nil)
        #expect(clearedUsage.subscriptionExpiresAt == nil)
    }
}
