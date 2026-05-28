import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CodexAccountSwitcherDragTests {
    @Test
    func `dragging a codex account reorders visible switcher buttons`() {
        let accounts = [
            self.account(id: "account-a", display: "alpha"),
            self.account(id: "account-b", display: "bravo"),
            self.account(id: "account-c", display: "charlie"),
        ]
        var selectedIDs: [String] = []
        var persistedOrders: [[String]] = []
        let view = CodexAccountSwitcherView(
            accounts: accounts,
            selectedAccountID: "account-a",
            width: 360,
            onSelect: { selectedIDs.append($0.id) },
            onReorder: { persistedOrders.append($0) })

        #expect(view._test_accountIDs() == ["account-a", "account-b", "account-c"])
        #expect(view._test_reorderAccount(id: "account-a", targetID: "account-c", dropAfterTarget: true))

        #expect(view._test_accountIDs() == ["account-b", "account-c", "account-a"])
        #expect(view._test_buttonTitles() == ["bravo", "charlie", "alpha"])
        #expect(persistedOrders == [["account-b", "account-c", "account-a"]])
        #expect(selectedIDs.isEmpty)
    }

    @Test
    func `codex account switcher order persists in defaults`() throws {
        let suite = "CodexAccountSwitcherDragTests-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        store.codexAccountSwitcherOrder = [" account-b ", "", "account-a", "account-b"]

        #expect(store.codexAccountSwitcherOrder == ["account-b", "account-a"])

        let reloaded = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(reloaded.codexAccountSwitcherOrder == ["account-b", "account-a"])
    }

    @Test
    func `reordering codex visible accounts changes projection order`() throws {
        let suite = "CodexAccountSwitcherDragTests-projection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let accountStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite)-accounts.json")
        defer {
            try? FileManager.default.removeItem(at: accountStoreURL)
            defaults.removePersistentDomain(forName: suite)
        }

        let homeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite)-homes", isDirectory: true)
        let accounts = ["alpha", "bravo", "charlie"].enumerated().map { index, display in
            ManagedCodexAccount(
                id: UUID(),
                email: display,
                managedHomePath: homeRoot.appendingPathComponent("\(index)", isDirectory: true).path,
                createdAt: 1,
                updatedAt: 1,
                lastAuthenticatedAt: 1)
        }
        try FileManagedCodexAccountStore(fileURL: accountStoreURL)
            .storeAccounts(ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: accounts))

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings._test_managedCodexAccountStoreURL = accountStoreURL

        let initialIDs = settings.codexVisibleAccountProjection.visibleAccounts.map(\.id)
        #expect(initialIDs.count == 3)

        settings.reorderCodexVisibleAccounts([initialIDs[2], initialIDs[0], initialIDs[1]])

        #expect(settings.codexVisibleAccountProjection.visibleAccounts.map(\.id) == [
            initialIDs[2],
            initialIDs[0],
            initialIDs[1],
        ])
    }

    private func account(id: String, display: String) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: id,
            email: display,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: id == "account-a",
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
    }
}
