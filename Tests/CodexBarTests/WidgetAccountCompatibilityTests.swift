import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct WidgetAccountCompatibilityTests {
    private let measuredAt = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `removing a Claude Swap sibling preserves the remaining pinned widget`() throws {
        let (settings, store) = self.makeStore(provider: .claude)
        settings.claudeSwapEnabled = true
        #expect(!settings.claudeSwapShowSingleAccount)
        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "work@example.com", usedPercent: 20),
            self.swapRow(number: 2, email: "personal@example.com", isActive: false, usedPercent: 70),
        ])
        let before = store.makeWidgetAccountEntries(now: self.measuredAt)
        let survivor = try #require(before.first { $0.usage?.primary?.usedPercent == 70 })

        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 2, email: "personal@example.com", usedPercent: 70),
        ])
        let after = store.makeWidgetAccountEntries(now: self.measuredAt.addingTimeInterval(300))
        #expect(after.count == 1)
        #expect(after.first?.id == survivor.id)
        #expect(self.pinnedUsage(id: survivor.id, provider: .claude, accounts: after)?.primary?.usedPercent == 70)
        #expect(after.first?.usage?.updatedAt == survivor.usage?.updatedAt)
        #expect(!settings.claudeSwapShowSingleAccount)
    }

    @Test
    func `reusing a Claude Swap slot cannot inherit another owners pinned widget`() throws {
        let (settings, store) = self.makeStore(provider: .claude)
        settings.claudeSwapEnabled = true
        settings.claudeSwapShowSingleAccount = true
        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "original@example.com", usedPercent: 20),
        ])
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)

        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "replacement@example.com", usedPercent: 80),
        ])
        let replacement = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(replacement.count == 1)
        #expect(replacement.first?.id != original.id)
        #expect(self.pinnedUsage(id: original.id, provider: .claude, accounts: replacement) == nil)
        let encoded = try #require(String(data: JSONEncoder().encode(replacement), encoding: .utf8))
        #expect(!encoded.contains("replacement@example.com"))
    }

    @Test
    func `renaming a Claude Swap alias leaves the pinned owner unchanged`() throws {
        let (settings, store) = self.makeStore(provider: .claude)
        settings.claudeSwapEnabled = true
        settings.claudeSwapShowSingleAccount = true
        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "work@example.com", alias: "Work", usedPercent: 20),
        ])
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)

        store.claudeSwapAccountSnapshots = self.swapAccounts([
            self.swapRow(number: 1, email: "work@example.com", alias: "Renamed", usedPercent: 25),
        ])
        let renamed = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(renamed.first?.id == original.id)
        #expect(self.pinnedUsage(id: original.id, provider: .claude, accounts: renamed)?.primary?.usedPercent == 25)
    }

    @Test
    func `Codex widget identity survives adding and removing a same email workspace`() throws {
        let (settings, store) = self.makeStore(provider: .codex)
        let owner = self.observedAccount(email: "member@example.com", workspace: "workspace-personal")
        let sibling = self.observedAccount(
            email: owner.email,
            workspace: "workspace-team",
            homeName: "team-profile")
        let alone = self.projection(owner: owner)
        let together = self.projection(owner: owner, siblings: [sibling])
        let originalRow = try #require(alone.visibleAccounts.first)
        let expandedRow = try #require(together.visibleAccounts.first { $0.isLive })
        // Menu row IDs intentionally disambiguate duplicate emails; saved widget IDs must not.
        #expect(originalRow.id != expandedRow.id)

        self.publishCodexProjection(alone, settings: settings, store: store)
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        self.publishCodexProjection(together, settings: settings, store: store)
        let expanded = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(expanded.count == 2)
        #expect(Set(expanded.map(\.id)).count == 2)
        #expect(self.pinnedUsage(id: original.id, provider: .codex, accounts: expanded)?.primary?.usedPercent == 20)

        self.publishCodexProjection(alone, settings: settings, store: store)
        let collapsed = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(collapsed.first?.id == original.id)
        #expect(self.pinnedUsage(id: original.id, provider: .codex, accounts: collapsed)?.primary?.usedPercent == 20)
    }

    @Test
    func `managed Codex pin survives promotion and credential rotation`() throws {
        let storedID = UUID()
        let managed = self.visibleAccount(
            source: .managedAccount(id: storedID),
            storedID: storedID,
            authFingerprint: "original-credential")
        let promoted = self.visibleAccount(
            source: .liveSystem,
            storedID: storedID,
            authFingerprint: "rotated-credential")
        let originalID = try #require(UsageStore.widgetCodexAccountID(managed))
        #expect(UsageStore.widgetCodexAccountID(promoted) == originalID)
    }

    @Test
    func `separate Codex profile homes have private independent pins for the same owner`() throws {
        let firstPath = CodexCredentialFixtures.root.appendingPathComponent("private-work-profile").path
        let secondPath = CodexCredentialFixtures.root.appendingPathComponent("private-personal-profile").path
        let first = self.visibleAccount(source: .profileHome(path: firstPath))
        let second = self.visibleAccount(source: .profileHome(path: secondPath))
        let firstID = try #require(UsageStore.widgetCodexAccountID(first))
        let secondID = try #require(UsageStore.widgetCodexAccountID(second))
        #expect(firstID != secondID)
        for id in [firstID, secondID] {
            #expect(!id.contains(first.email))
            #expect(!id.contains(firstPath))
            #expect(!id.contains(secondPath))
            #expect(!id.contains("private-work-profile"))
            #expect(!id.contains("private-personal-profile"))
        }
    }

    @Test
    func `replacing a live or profile Codex workspace changes its pinned owner`() throws {
        let sources: [CodexActiveSource] = [.liveSystem, .profileHome(path: "/synthetic/profile")]
        for source in sources {
            let original = self.visibleAccount(source: source, workspace: "workspace-personal")
            let replacement = self.visibleAccount(source: source, workspace: "workspace-team")
            let originalID = try #require(UsageStore.widgetCodexAccountID(original))
            let replacementID = try #require(UsageStore.widgetCodexAccountID(replacement))
            #expect(replacementID != originalID)
        }
    }

    @Test
    func `different Codex members of one workspace cannot share a live or profile pin`() throws {
        let sources: [CodexActiveSource] = [.liveSystem, .profileHome(path: "/synthetic/profile")]
        for source in sources {
            let original = self.visibleAccount(source: source, email: "first-member@example.com")
            let replacement = self.visibleAccount(source: source, email: "second-member@example.com")
            let originalID = try #require(UsageStore.widgetCodexAccountID(original))
            let replacementID = try #require(UsageStore.widgetCodexAccountID(replacement))
            #expect(replacementID != originalID)
        }
    }

    @Test
    func `unresolved live and profile Codex owners cannot create durable pins`() {
        let sources: [CodexActiveSource] = [.liveSystem, .profileHome(path: "/synthetic/profile")]
        for source in sources {
            let unresolved = self.visibleAccount(
                source: source,
                email: " \n",
                workspace: nil,
                authFingerprint: "credential-without-owner")
            #expect(UsageStore.widgetCodexAccountID(unresolved) == nil)
        }
    }

    @Test
    func `single Codex account retains its measured quota through transient refresh failures`() async throws {
        let (settings, store) = self.makeStore(provider: .codex)
        let owner = self.observedAccount(email: "member@example.com", workspace: "workspace-personal")
        self.installReconciliation(owner: owner, settings: settings)
        self.installFetch(on: store) { self.usage(email: owner.email, usedPercent: 20) }
        await store.refreshProvider(.codex)
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        #expect(original.usage?.updatedAt == self.measuredAt)

        let offline = URLError(.notConnectedToInternet)
        #expect(UsageStore.shouldPreservePriorSnapshot(after: offline, hadPriorData: true))
        self.installFetch(on: store) { throw offline }
        for _ in 0..<2 {
            await store.refreshProvider(.codex)
            let retained = store.makeWidgetAccountEntries(now: self.measuredAt.addingTimeInterval(600))
            #expect(retained.first?.id == original.id)
            let usage = try #require(self.pinnedUsage(id: original.id, provider: .codex, accounts: retained))
            #expect(usage.primary?.usedPercent == 20)
            #expect(usage.updatedAt == self.measuredAt)
        }
    }

    @Test
    func `single Codex account removes pinned quota after authentication failure`() async throws {
        let (settings, store) = self.makeStore(provider: .codex)
        let owner = self.observedAccount(email: "member@example.com", workspace: "workspace-personal")
        self.installReconciliation(owner: owner, settings: settings)
        self.installFetch(on: store) { self.usage(email: owner.email, usedPercent: 20) }
        await store.refreshProvider(.codex)
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        #expect(original.usage != nil)

        self.installFetch(on: store) { throw TestRefreshError(message: "401 Unauthorized") }
        await store.refreshProvider(.codex)
        let unavailable = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(unavailable.first?.id == original.id)
        #expect(self.pinnedUsage(id: original.id, provider: .codex, accounts: unavailable) == nil)
    }

    @Test
    func `single Codex account cannot retain another workspace quota after an owner change`() async throws {
        let (settings, store) = self.makeStore(provider: .codex)
        let originalOwner = self.observedAccount(email: "member@example.com", workspace: "workspace-personal")
        self.installReconciliation(owner: originalOwner, settings: settings)
        self.installFetch(on: store) { self.usage(email: originalOwner.email, usedPercent: 20) }
        await store.refreshProvider(.codex)
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        #expect(original.usage != nil)

        let replacementOwner = self.observedAccount(email: originalOwner.email, workspace: "workspace-team")
        self.installReconciliation(owner: replacementOwner, settings: settings)
        let offline = URLError(.notConnectedToInternet)
        #expect(UsageStore.shouldPreservePriorSnapshot(after: offline, hadPriorData: true))
        self.installFetch(on: store) { throw offline }
        await store.refreshProvider(.codex)
        let replacement = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(replacement.count == 1)
        #expect(replacement.first?.id != original.id)
        #expect(replacement.first?.usage == nil)
        #expect(self.pinnedUsage(id: original.id, provider: .codex, accounts: replacement) == nil)
    }

    private func makeStore(provider: UsageProvider) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(
            suiteName: "WidgetAccountCompatibilityTests",
            userDefaults: InMemoryUserDefaults())
        settings.providerDetectionCompleted = true
        settings.setProviderEnabled(provider: provider, metadata: ProviderDefaults.metadata[provider]!, enabled: true)
        settings.accountWidgetsEnabled = true
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .segmented
        settings.statusChecksEnabled = false
        settings.codexCookieSource = .off
        let root = CodexCredentialFixtures.root
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config").path,
        ]
        settings._test_codexReconciliationEnvironment = environment
        settings._test_codexAccountSnapshotLoader = { _ in
            CodexAccountReconciliationSnapshot(
                storedAccounts: [],
                activeStoredAccount: nil,
                liveSystemAccount: nil,
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: .liveSystem,
                hasUnreadableAddedAccountStore: false)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: RecordingCodexAccountUsageSnapshotStore(initialSnapshots: []),
            startupBehavior: .testing,
            environmentBase: environment,
            widgetTimelineReloader: {})
        return (settings, store)
    }

    private func swapRow(
        number: Int,
        email: String,
        alias: String? = nil,
        isActive: Bool = true,
        usedPercent: Double) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            alias: alias,
            isActive: isActive,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: usedPercent, resetsAt: nil),
            sevenDay: nil,
            usageFetchedAt: self.measuredAt)
    }

    private func swapAccounts(_ rows: [ClaudeSwapAccountRow]) -> [ProviderAccountUsageSnapshot] {
        ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(activeAccountNumber: rows.first?.number, accounts: rows),
            now: self.measuredAt)
    }

    private func observedAccount(
        email: String,
        workspace: String,
        homeName: String = ".codex") -> ObservedSystemCodexAccount
    {
        ObservedSystemCodexAccount(
            email: email,
            workspaceAccountID: workspace,
            codexHomePath: CodexCredentialFixtures.root.appendingPathComponent(homeName).path,
            observedAt: self.measuredAt,
            identity: .providerAccount(id: workspace))
    }

    private func visibleAccount(
        source: CodexActiveSource,
        email: String = "member@example.com",
        workspace: String? = "workspace-personal",
        storedID: UUID? = nil,
        authFingerprint: String? = nil) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: "presentation-row",
            email: email,
            workspaceAccountID: workspace,
            authFingerprint: authFingerprint,
            storedAccountID: storedID,
            selectionSource: source,
            isActive: true,
            isLive: source == .liveSystem,
            canReauthenticate: false,
            canRemove: false)
    }

    private func reconciliation(
        owner: ObservedSystemCodexAccount,
        siblings: [ObservedSystemCodexAccount] = []) -> CodexAccountReconciliationSnapshot
    {
        CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: owner,
            profileHomeAccounts: siblings,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .liveSystem,
            hasUnreadableAddedAccountStore: false)
    }

    private func projection(
        owner: ObservedSystemCodexAccount,
        siblings: [ObservedSystemCodexAccount] = []) -> CodexVisibleAccountProjection
    {
        CodexVisibleAccountProjection.make(from: self.reconciliation(owner: owner, siblings: siblings))
    }

    private func publishCodexProjection(
        _ projection: CodexVisibleAccountProjection,
        settings: SettingsStore,
        store: UsageStore)
    {
        settings.cachedCodexAccountMenuProjection = CachedCodexAccountMenuProjection(
            activeSource: .liveSystem,
            loadedAt: self.measuredAt,
            projection: projection)
        store.codexAccountSnapshots = projection.visibleAccounts.map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.usage(email: account.email, usedPercent: account.isLive ? 20 : 80),
                error: nil,
                sourceLabel: "fixture")
        }
    }

    private func installReconciliation(owner: ObservedSystemCodexAccount, settings: SettingsStore) {
        let snapshot = self.reconciliation(owner: owner)
        settings._test_codexAccountSnapshotLoader = { _ in snapshot }
        settings.invalidateCodexAccountReconciliationSnapshotCache()
    }

    private func installFetch(
        on store: UsageStore,
        loader: @escaping @Sendable () async throws -> UsageSnapshot)
    {
        store.providerSpecs[.codex] = CodexAccountScopedRefreshTests.makeCodexProviderSpec(
            baseSpec: store.providerSpecs[.codex]!, loader: loader)
    }

    private nonisolated func usage(email: String, usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.measuredAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    private func pinnedUsage(
        id: String,
        provider: UsageProvider,
        accounts: [WidgetSnapshot.AccountEntry]) -> WidgetSnapshot.ProviderEntry?
    {
        WidgetSnapshot(
            entries: [],
            accounts: accounts,
            enabledProviders: [provider.instanceID],
            generatedAt: self.measuredAt)
            .selectingAccount(id, for: provider).entries.first { $0.provider == provider.instanceID }
    }
}
