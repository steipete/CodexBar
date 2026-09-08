import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `credits fallback preserves same provider owner across auth fingerprint rotation`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-credits-provider-fingerprint-rotation")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            workspaceAccountID: "acct-alpha",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))

        let store = self.makeUsageStore(settings: settings)
        let cachedCredits = self.credits(remaining: 12)
        store.lastCreditsSnapshot = cachedCredits
        store.lastCreditsSnapshotAccountKey = "alpha@example.com"
        store.lastCreditsSnapshotOwnerGuard = store.freshCodexAccountScopedRefreshGuard()
        store._test_codexCreditsLoaderOverride = {
            throw TestRefreshError(message: "Codex credits data not available yet")
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            workspaceAccountID: "acct-alpha",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))

        await store.refreshCreditsIfNeeded()

        #expect(store.credits == cachedCredits)
        #expect(store.lastCreditsError == nil)
    }
}
