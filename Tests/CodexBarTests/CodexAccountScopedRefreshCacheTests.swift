import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `cancelled codex usage refresh preserves last good snapshot without surfacing error`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-cancelled-refresh")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        let cached = self.codexSnapshot(email: "alpha@example.com", usedPercent: 17)
        store._setSnapshotForTesting(cached, provider: .codex)
        self.installFailingCodexProvider(on: store, error: TestRefreshError(message: "Network error: cancelled"))

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "alpha@example.com")
        #expect(store.snapshots[.codex]?.primary?.usedPercent == 17)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `account transition reuses cached snapshot for selected visible codex account`() throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-cached-selected-account")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "beta@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 9), provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)

        let betaAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts
            .first { $0.email == "beta@example.com" })
        let betaSnapshot = self.codexSnapshot(email: "beta@example.com", usedPercent: 41)
        store.codexAccountSnapshots = [
            CodexAccountUsageSnapshot(
                account: betaAccount,
                snapshot: betaSnapshot,
                error: nil,
                sourceLabel: "cached"),
        ]

        settings.selectDisplayedCodexVisibleAccount(betaAccount)
        let didInvalidate = store.prepareCodexAccountScopedRefreshIfNeeded()

        #expect(didInvalidate)
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "beta@example.com")
        #expect(store.snapshots[.codex]?.primary?.usedPercent == 41)
        #expect(store.lastSourceLabels[.codex] == "cached")
        #expect(store.errors[.codex] == nil)
        #expect(store.codexAccountSnapshots.count == 1)
    }
}
