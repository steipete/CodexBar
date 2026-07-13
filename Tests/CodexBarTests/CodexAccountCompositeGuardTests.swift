import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `shared workspace rejects stale member results without fingerprints`() {
        self.assertSharedWorkspaceMemberSwitchRejectsStaleResults(
            suite: "CodexAccountScopedRefreshTests-shared-workspace-nil-fingerprint",
            authFingerprint: nil)
    }

    @Test
    func `shared workspace rejects stale member results with stable fingerprints`() {
        self.assertSharedWorkspaceMemberSwitchRejectsStaleResults(
            suite: "CodexAccountScopedRefreshTests-shared-workspace-stable-fingerprint",
            authFingerprint: "stable-auth")
    }

    @Test
    func `provider identity without email fails every scoped guard closed`() {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-provider-identity-missing-email")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.providerAccount(
            email: "   ",
            authFingerprint: nil,
            workspaceLabel: "Workspace")

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .providerAccount(id: "shared-workspace"),
            accountKey: nil,
            authFingerprint: nil)

        self.expectEveryScopedGuardRejects(
            store: store,
            expectedGuard: expectedGuard,
            staleEmail: nil)
        #expect(!UsageStore.codexScopedRefreshGuardsMatchAccount(expectedGuard, expectedGuard))
    }

    @Test
    func `same member auth rotation keeps success admission policy`() {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-same-member-auth-rotation")
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.providerAccount(
            email: "Member@Example.com",
            authFingerprint: "old-auth",
            workspaceLabel: "Old label")

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexAccountScopedRefreshGuard()

        settings._test_liveSystemCodexAccount = self.providerAccount(
            email: " member@example.com ",
            authFingerprint: "new-auth",
            workspaceLabel: "New label")

        let usage = self.codexSnapshot(email: "member@example.com", usedPercent: 25)
        #expect(store.shouldApplyCodexUsageResult(expectedGuard: expectedGuard, usage: usage))
        #expect(store.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard))
        #expect(store.shouldApplyOpenAIDashboardRefreshGuard(
            expectedGuard: expectedGuard,
            routingTargetEmail: "member@example.com"))
        #expect(store.shouldApplyOpenAIDashboardPolicyResult(
            expectedGuard: expectedGuard,
            routingTargetEmail: "member@example.com"))
        #expect(!store.shouldApplyCodexScopedFailure(expectedGuard: expectedGuard))
        #expect(!store.shouldApplyCodexScopedNonUsageFailure(expectedGuard: expectedGuard))
        #expect(!store.shouldApplyOpenAIWebNonSuccessResult(
            expectedGuard: expectedGuard,
            routingTargetEmail: "member@example.com"))
    }

    private func assertSharedWorkspaceMemberSwitchRejectsStaleResults(
        suite: String,
        authFingerprint: String?)
    {
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = self.providerAccount(
            email: "alpha@example.com",
            authFingerprint: authFingerprint,
            workspaceLabel: "Alpha")

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexAccountScopedRefreshGuard()
        #expect(expectedGuard.identity == .providerAccount(id: "shared-workspace"))
        #expect(expectedGuard.accountKey == "alpha@example.com")

        settings._test_liveSystemCodexAccount = self.providerAccount(
            email: "beta@example.com",
            authFingerprint: authFingerprint,
            workspaceLabel: "Beta")

        self.expectEveryScopedGuardRejects(
            store: store,
            expectedGuard: expectedGuard,
            staleEmail: "alpha@example.com")
        #expect(!UsageStore.codexScopedRefreshGuardsMatchAccount(
            expectedGuard,
            store.freshCodexAccountScopedRefreshGuard()))
    }

    private func expectEveryScopedGuardRejects(
        store: UsageStore,
        expectedGuard: CodexAccountScopedRefreshGuard,
        staleEmail: String?)
    {
        let usage = self.codexSnapshot(email: staleEmail ?? "", usedPercent: 25)
        #expect(!store.shouldApplyCodexUsageResult(expectedGuard: expectedGuard, usage: usage))
        #expect(!store.shouldApplyCodexScopedFailure(expectedGuard: expectedGuard))
        #expect(!store.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard))
        #expect(!store.shouldApplyCodexScopedNonUsageFailure(expectedGuard: expectedGuard))
        #expect(!store.shouldApplyOpenAIDashboardRefreshGuard(
            expectedGuard: expectedGuard,
            routingTargetEmail: staleEmail))
        #expect(!store.shouldApplyOpenAIWebNonSuccessResult(
            expectedGuard: expectedGuard,
            routingTargetEmail: staleEmail))
        #expect(!store.shouldApplyOpenAIDashboardPolicyResult(
            expectedGuard: expectedGuard,
            routingTargetEmail: staleEmail))
    }

    private func providerAccount(
        email: String,
        authFingerprint: String?,
        workspaceLabel: String) -> ObservedSystemCodexAccount
    {
        ObservedSystemCodexAccount(
            email: email,
            workspaceLabel: workspaceLabel,
            workspaceAccountID: "shared-workspace",
            authFingerprint: authFingerprint,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "shared-workspace"))
    }
}
