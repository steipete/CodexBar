import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `display only dashboard cannot persist subscription metadata`() async throws {
        let settings = CodexManagedOpenAIWebTests()
            .makeSettingsStore(suite: "CodexAccountScopedRefreshTests-display-only-subscription")
        let managedHome = CodexCredentialFixtures.root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "shared@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: managedStoreURL)
        }

        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "shared@example.com",
            identity: .emailOnly(normalizedEmail: "shared@example.com"))
        settings.codexActiveSource = .liveSystem

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            self.codexSnapshot(email: "shared@example.com", usedPercent: 20),
            provider: .codex)
        store.lastSourceLabels[.codex] = "codex-cli"
        var persistedWidgets: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { persistedWidgets.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        let dashboardRenewal = Date(timeIntervalSince1970: 1_788_000_000)
        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: "shared@example.com",
                codeReviewRemainingPercent: nil,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                creditsRemaining: nil,
                accountPlan: "Pro",
                subscriptionRenewsAt: dashboardRenewal,
                updatedAt: Date()),
            targetEmail: "shared@example.com",
            allowCodexUsageBackfill: false)
        await store.widgetSnapshotPersistTask?.value

        #expect(store.openAIDashboard?.subscriptionRenewsAt == dashboardRenewal)
        #expect(!store.openAIDashboardAttachmentAuthorized)
        #expect(store.snapshots[.codex] == nil)
        #expect(persistedWidgets.allSatisfy { snapshot in
            !snapshot.entries.contains { $0.provider == .codex }
        })
        let expectedLog = "subscription metadata skipped: authority=display-only "
            + "reason=same-email-ambiguity persistence=not-attempted"
        #expect(store.openAIDashboardCookieImportDebugLog?.contains(expectedLog) == true)
    }
}
