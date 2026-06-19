import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `banked resets fallback only reuses cache for the same codex account`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-banked-resets")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        let cachedResets = self.bankedResets(count: 2)
        store._setSnapshotForTesting(self.codexSnapshot(email: "alpha@example.com", usedPercent: 10), provider: .codex)
        store.lastBankedResetsSnapshot = cachedResets
        store.lastBankedResetsSnapshotAccountKey = "alpha@example.com"
        store._test_codexBankedResetsLoaderOverride = {
            throw TestRefreshError(message: "Codex banked resets data not available yet")
        }
        defer { store._test_codexBankedResetsLoaderOverride = nil }

        await store.refreshBankedResetsIfNeeded()
        #expect(store.bankedResets == cachedResets)
        #expect(store.lastBankedResetsError == nil)

        settings._test_liveSystemCodexAccount = self.liveAccount(email: "beta@example.com")
        store._setSnapshotForTesting(self.codexSnapshot(email: "beta@example.com", usedPercent: 10), provider: .codex)

        await store.refreshBankedResetsIfNeeded()
        #expect(store.bankedResets == nil)
        #expect(store.lastBankedResetsError == "Codex banked resets are still loading; will retry shortly.")
    }

    @Test
    func `refresh loads banked resets when codex email is discovered by usage in the same cycle`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-refresh-banked-resets")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "alpha@example.com",
            identity: .providerAccount(id: "acct-alpha"))

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)
        store._test_codexBankedResetsLoaderOverride = { self.bankedResets(count: 2) }
        defer { store._test_codexBankedResetsLoaderOverride = nil }

        let refreshTask = Task { await store.refresh() }
        await blocker.waitUntilStarted()
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 12)))
        await refreshTask.value
        #expect(store.lastCodexAccountScopedRefreshGuard?.accountKey == "alpha@example.com")

        await store.bankedResetsRefreshTask?.value

        #expect(store.bankedResets?.availableCount == 2)
        #expect(store.lastBankedResetsError == nil)
    }

    @Test
    func `codex provider refresh schedules banked resets refresh`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-provider-refresh-banked-resets")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "alpha@example.com",
            identity: .providerAccount(id: "acct-alpha"))

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)
        store._test_codexBankedResetsLoaderOverride = { self.bankedResets(count: 2) }
        defer { store._test_codexBankedResetsLoaderOverride = nil }

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 12)))
        await refreshTask.value

        await store.bankedResetsRefreshTask?.value

        #expect(store.bankedResets?.availableCount == 2)
        #expect(store.lastBankedResetsError == nil)
    }

    @Test
    func `banked resets survive live identity enrichment from email to provider account`() {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-banked-resets-identity-bridge")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "alpha@example.com",
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))

        let store = self.makeUsageStore(settings: settings)
        let cachedResets = self.bankedResets(count: 2)
        store.bankedResets = cachedResets
        store.lastBankedResetsSnapshot = cachedResets
        store.lastBankedResetsSnapshotAccountKey = "alpha@example.com"
        let emailOnlyGuard = store.currentCodexAccountScopedRefreshGuard()
        store.lastCodexAccountScopedRefreshGuard = emailOnlyGuard
        #expect(emailOnlyGuard.identity == .emailOnly(normalizedEmail: "alpha@example.com"))

        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "alpha@example.com",
            identity: .providerAccount(id: "acct-alpha"))

        let applyGuard = store.codexScopedNonUsageSuccessApplyGuard(expectedGuard: emailOnlyGuard)
        #expect(applyGuard?.identity == .providerAccount(id: "acct-alpha"))

        let didInvalidate = store.prepareCodexAccountScopedRefreshIfNeeded()

        #expect(!didInvalidate)
        #expect(store.bankedResets == cachedResets)
        #expect(store.lastBankedResetsSnapshot == cachedResets)
        #expect(store.lastCodexAccountScopedRefreshGuard?.identity == .providerAccount(id: "acct-alpha"))
    }
}
