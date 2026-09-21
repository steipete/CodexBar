import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexAccountMenuPhaseFixture {
    let navigation: CodexWorkspacesNavigationFixture
    let gate = CodexAccountMenuPhaseGate()
    let managedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111")!

    var settings: SettingsStore {
        self.navigation.settings
    }

    var store: UsageStore {
        self.navigation.store
    }

    init() throws {
        self.navigation = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        let settings = self.settings
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false
        settings.multiAccountMenuLayout = .segmented
        settings.usageBarsShowUsed = true
        settings.hidePersonalInfo = false
        settings.agentSessionsEnabled = false
        settings.codexCookieSource = .off
        let root = self.navigation.files.root
        let managedHome = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        let accountsURL = root.appendingPathComponent("managed-accounts.json")
        try FileManagedCodexAccountStore(fileURL: accountsURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [ManagedCodexAccount(
                id: self.managedID,
                email: "account-b@example.invalid",
                managedHomePath: managedHome.path,
                createdAt: 1,
                updatedAt: 2,
                lastAuthenticatedAt: 2)]))
        settings._test_managedCodexAccountStoreURL = accountsURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "account-a@example.invalid",
            codexHomePath: self.navigation.files.codexHomeRoot.path,
            observedAt: Date())
        settings.codexActiveSource = .liveSystem
        settings.setProviderEnabled(
            provider: .claude,
            metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
            enabled: true)
        let store = self.store
        store._setSnapshotForTesting(
            Self.snapshot(email: "auxiliary@example.invalid", percent: 29, provider: .claude), provider: .claude)
        store._setSnapshotForTesting(Self.snapshot(email: "account-a@example.invalid", percent: 11), provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store.currentCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: false)
        let gate = self.gate
        store._test_providerRefreshOverride = nil
        // Keep real account-ownership publication and credits reconciliation around the synthetic fetch.
        for provider in [UsageProvider.codex, .claude] {
            let spec = try #require(store.providerSpecs[provider])
            let base = spec.descriptor
            let strategy = CodexAccountMenuPhaseStrategy(provider: provider, gate: gate)
            let descriptor = ProviderDescriptor(
                id: provider,
                metadata: base.metadata,
                branding: base.branding,
                tokenCost: base.tokenCost,
                pace: base.pace,
                history: base.history,
                presentation: base.presentation,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .cli, .oauth, .web, .api],
                    pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: base.cli)
            store.providerSpecs[provider] = ProviderSpec(
                style: spec.style,
                isEnabled: spec.isEnabled,
                descriptor: descriptor,
                makeFetchContext: spec.makeFetchContext)
        }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 12, events: [], updatedAt: Date())
        }
        store._test_codexAccountScopedRefreshDidComplete = { gate.completed = true }
    }

    func managedVisibleAccount() throws -> CodexVisibleAccount {
        try #require(self.settings.codexVisibleAccountProjection.visibleAccounts.first {
            $0.storedAccountID == self.managedID
        })
    }

    func makeController() -> StatusItemController {
        self.navigation.makeController()
    }

    func cleanup() {
        self.gate.release()
        self.store._test_providerRefreshOverride = nil
        self.store._test_codexCreditsLoaderOverride = nil
        self.store._test_codexAccountScopedRefreshDidComplete = nil
        self.settings._test_managedCodexAccountStoreURL = nil
        self.settings._test_liveSystemCodexAccount = nil
        self.navigation.cleanup()
    }

    nonisolated static func snapshot(
        email: String,
        percent: Double,
        provider: UsageProvider = .codex) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: percent,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Plus"))
    }
}

@MainActor
final class CodexAccountMenuPhaseGate {
    private(set) var entered = false
    private(set) var startCount = 0
    var completed = false
    var requestedUnexpectedProvider = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        self.entered = true
        self.startCount += 1
        guard !self.released else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func release() {
        self.released = true
        for continuation in self.continuations {
            continuation.resume()
        }
        self.continuations.removeAll()
    }
}

private struct CodexAccountMenuPhaseStrategy: ProviderFetchStrategy {
    let provider: UsageProvider
    let gate: CodexAccountMenuPhaseGate

    var id: String {
        "synthetic-account-menu"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard self.provider == .codex else {
            await MainActor.run { self.gate.requestedUnexpectedProvider = true }
            throw URLError(.unsupportedURL)
        }
        await self.gate.wait()
        return self.makeResult(
            usage: CodexAccountMenuPhaseFixture.snapshot(email: "account-b@example.invalid", percent: 17),
            sourceLabel: "synthetic-account-menu")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}
