import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusMenuCodexSwitcherPresentationTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuCodexSwitcherPresentationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeManagedAccountStoreURL(accounts: [ManagedCodexAccount]) throws -> URL {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))
        return storeURL
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func representedIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }
    }

    private func snapshot(email: String, percent: Double = 12) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: percent,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(300),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: percent,
                windowMinutes: 10080,
                resetsAt: Date().addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Plus"))
    }

    @Test
    func `codex account ordering keeps workspace groups contiguous`() {
        let teamActive = CodexVisibleAccount(
            id: "team-a-active",
            email: "active@example.com",
            workspaceLabel: "Team A",
            workspaceAccountID: "team-a",
            storedAccountID: UUID(),
            selectionSource: .managedAccount(id: UUID()),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let teamHighQuota = CodexVisibleAccount(
            id: "team-b-high-quota",
            email: "high@example.com",
            workspaceLabel: "Team B",
            workspaceAccountID: "team-b",
            storedAccountID: UUID(),
            selectionSource: .managedAccount(id: UUID()),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let teamSibling = CodexVisibleAccount(
            id: "team-a-sibling",
            email: "sibling@example.com",
            workspaceLabel: "Team A",
            workspaceAccountID: "team-a",
            storedAccountID: UUID(),
            selectionSource: .managedAccount(id: UUID()),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let accounts = [teamActive, teamHighQuota, teamSibling]
        let snapshots = [
            CodexAccountUsageSnapshot(
                account: teamActive,
                snapshot: self.snapshot(email: teamActive.email, percent: 95),
                error: nil,
                sourceLabel: "test"),
            CodexAccountUsageSnapshot(
                account: teamHighQuota,
                snapshot: self.snapshot(email: teamHighQuota.email, percent: 10),
                error: nil,
                sourceLabel: "test"),
            CodexAccountUsageSnapshot(
                account: teamSibling,
                snapshot: self.snapshot(email: teamSibling.email, percent: 20),
                error: nil,
                sourceLabel: "test"),
        ]

        let ordered = CodexAccountPresentationOrdering.orderedAccounts(
            accounts,
            snapshots: snapshots,
            activeVisibleAccountID: teamActive.id)

        #expect(ordered.map(\.id) == ["team-a-active", "team-a-sibling", "team-b-high-quota"])
        #expect(ordered.codexWorkspaceSections().map(\.title) == ["Team A", "Team B"])
        #expect(ordered.codexWorkspaceSections().first?.accounts.map(\.id) == ["team-a-active", "team-a-sibling"])
    }

    @Test
    func `codex stacked menu orders by quota and groups workspaces`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
        self.enableOnlyCodex(settings)

        let lowID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let highID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let low = ManagedCodexAccount(
            id: lowID,
            email: "low@example.com",
            workspaceLabel: "Team Low",
            workspaceAccountID: "team-low",
            managedHomePath: "/tmp/low-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let high = ManagedCodexAccount(
            id: highID,
            email: "high@example.com",
            workspaceLabel: "Team High",
            workspaceAccountID: "team-high",
            managedHomePath: "/tmp/high-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [low, high])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "active@example.com",
            workspaceLabel: "Personal",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.codexAccountSnapshots = settings.codexVisibleAccountProjection.visibleAccounts.map { account in
            let usedPercent = switch account.email {
            case "high@example.com":
                10.0
            case "low@example.com":
                80.0
            default:
                95.0
            }
            return CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(email: account.email, percent: usedPercent),
                error: nil,
                sourceLabel: "test")
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let display = try #require(controller.codexAccountMenuDisplay(for: .codex))
        #expect(display.accounts.map(\.email) == ["active@example.com", "high@example.com", "low@example.com"])
        #expect(display.workspaceSections.map(\.title) == ["Personal", "Team High", "Team Low"])

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        #expect(self.representedIDs(in: menu).count(where: { $0.hasPrefix("codexWorkspace-") }) == 3)
    }

    @Test
    func `codex stacked menu surfaces account health labels`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
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
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        let visibleAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts
            .first { $0.email == "managed@example.com" })

        #expect(CodexAccountHealth.status(for: visibleAccount, error: "401 Unauthorized")
            .label == "Needs re-auth")
    }

    @Test
    func `codex account snapshot store hydrates current visible accounts`() {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let account = CodexVisibleAccount(
            id: "active@example.com",
            email: "active@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let store = FileCodexAccountUsageSnapshotStore(fileURL: fileURL)
        store.store([
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(email: account.email, percent: 17),
                error: nil,
                sourceLabel: "test"),
        ])

        let hydrated = store.load(for: [account])

        #expect(hydrated.map(\.id) == [account.id])
        #expect(hydrated.first?.snapshot?.primary?.usedPercent == 17)
        #expect(hydrated.first?.account.email == account.email)
    }
}
