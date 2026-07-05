import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Active claude-swap accounts must replace Claude token-account presentation:
/// with multiple token accounts in stacked layout, the token-account branch
/// would otherwise render first and silently hide the adapter's rows.
@MainActor
struct ClaudeSwapMenuPrecedenceTests {
    private func makeController() throws -> (StatusItemController, UsageStore, SettingsStore) {
        let suite = "ClaudeSwapMenuPrecedenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        return (controller, store, settings)
    }

    private func makeClaudeSwapSnapshot(slot: Int, isActive: Bool) -> ProviderAccountUsageSnapshot {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: String(slot)),
            provider: .claude,
            displayLabel: "account\(slot)@example.com",
            isActive: isActive,
            snapshot: nil,
            error: "Usage fetch failed.",
            sourceLabel: "claude-swap")
    }

    @Test
    func `claude swap accounts suppress token account menu display`() throws {
        let (controller, store, settings) = try self.makeController()
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .claude, label: "First", token: "sk-ant-oat-first")
        settings.addTokenAccount(provider: .claude, label: "Second", token: "sk-ant-oat-second")

        #expect(controller.tokenAccountMenuDisplay(for: .claude) != nil)

        store.claudeSwapAccountSnapshots = [
            self.makeClaudeSwapSnapshot(slot: 1, isActive: true),
            self.makeClaudeSwapSnapshot(slot: 2, isActive: false),
        ]
        #expect(controller.tokenAccountMenuDisplay(for: .claude) == nil)

        store.claudeSwapAccountSnapshots = [self.makeClaudeSwapSnapshot(slot: 1, isActive: true)]
        #expect(controller.tokenAccountMenuDisplay(for: .claude) != nil)
    }

    @Test
    func `claude swap accounts leave other providers' token account display alone`() throws {
        let (controller, store, settings) = try self.makeController()
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .openai, label: "First", token: "sk-first")
        settings.addTokenAccount(provider: .openai, label: "Second", token: "sk-second")

        store.claudeSwapAccountSnapshots = [
            self.makeClaudeSwapSnapshot(slot: 1, isActive: true),
            self.makeClaudeSwapSnapshot(slot: 2, isActive: false),
        ]
        #expect(controller.tokenAccountMenuDisplay(for: .openai) != nil)
    }
}
