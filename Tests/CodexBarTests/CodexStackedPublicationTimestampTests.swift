import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// The Codex window keep-alive only pings after a *fresh* successful publication. Stacked layouts publish the
/// selected account through `applySelectedCodexVisibleAccountOutcome`, so that path must stamp the same timestamp
/// as the ordinary `refreshProvider` success path, and failures must not.
extension CodexAccountScopedRefreshTests {
    @Test
    func `stacked selected-account success stamps the Codex publication time`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-stacked-publication-stamp")
        let (store, liveAccount) = try self.makeStackedStore(settings: settings)
        defer { self.tearDownStackedStore(settings: settings) }
        let usage = self.codexSnapshot(email: liveAccount.email, usedPercent: 12)
        let strategy = TestCodexFetchStrategy(
            loader: { usage },
            credits: nil,
            id: "stacked-stamp-success",
            kind: .apiToken,
            sourceLabel: "api")
        let baseSpec = try #require(store.providerSpecs[.codex])
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) { _ in [strategy] }
        #expect(store.lastSnapshotPublicationAt[.codex] == nil)
        let refreshStartedAt = Date()

        await store.refreshCodexVisibleAccountsForMenu()

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 12)
        let publishedAt = try #require(store.lastSnapshotPublicationAt[.codex])
        #expect(publishedAt >= refreshStartedAt)
    }

    @Test
    func `stacked selected-account failure leaves the Codex publication time unset`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-stacked-publication-failure")
        let (store, _) = try self.makeStackedStore(settings: settings)
        defer { self.tearDownStackedStore(settings: settings) }
        let strategy = ThrowingTestCodexFetchStrategy {
            throw TestRefreshError(message: "The network connection was lost.")
        }
        let baseSpec = try #require(store.providerSpecs[.codex])
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) { _ in [strategy] }

        await store.refreshCodexVisibleAccountsForMenu()

        #expect(store.lastSnapshotPublicationAt[.codex] == nil)
    }

    // MARK: - Helpers

    /// A stacked layout with the live system account selected plus one added account, so the fan-out path runs.
    private func makeStackedStore(settings: SettingsStore) throws -> (UsageStore, CodexVisibleAccount) {
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "biz@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        settings._test_managedCodexAccountStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])

        let liveAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts.first {
            $0.email == "biz@example.com"
        })
        let store = self.makeUsageStore(settings: settings)
        store._test_codexResetCreditsFetcherOverride = { _ in nil }
        return (store, liveAccount)
    }

    private func tearDownStackedStore(settings: SettingsStore) {
        if let url = settings._test_managedCodexAccountStoreURL {
            try? FileManager.default.removeItem(at: url)
        }
        settings._test_managedCodexAccountStoreURL = nil
        settings._test_liveSystemCodexAccount = nil
    }
}
