import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Lane-activation tests for the opt-in OpenCode local history source (#3273 contract):
/// enabling it must surface the ambient Codex menu-history lane on its own, while the
/// shared cost-usage gate — and every Spend Dashboard path that consults it — stays
/// untouched for users who never opted in.
@MainActor
struct OpenCodeLocalHistorySettingsTests {
    @Test
    func `opencode opt-in activates the ambient codex history lane`() throws {
        let settings = testSettingsStore(suiteName: "OpenCodeLocalHistorySettingsTests-lane")
        // Default-off: the ambient lane follows the shared cost-usage gate.
        #expect(!settings.costUsageEnabled)
        #expect(!settings.codexLocalSessionCostLedgerEnabled)
        #expect(!settings.codexIncludeOpenCodeLocalHistory)
        #expect(!settings.isCostUsageEffectivelyEnabled(for: .codex))
        #expect(!settings.isHistoryLaneEffectivelyEnabled(for: .codex))

        // Opting into OpenCode local history alone activates the ambient Codex
        // menu-history lane, so a user whose only source is OpenCode needs no second
        // toggle to see the merged history.
        settings.codexIncludeOpenCodeLocalHistory = true
        #expect(settings.isHistoryLaneEffectivelyEnabled(for: .codex))
        // The shared gate stays off — other providers and the Spend Dashboard paths
        // that consult it never activate through this opt-in.
        #expect(!settings.isCostUsageEffectivelyEnabled(for: .codex))
        #expect(!settings.isCostUsageEffectivelyEnabled(for: .claude))

        // The classic toggles keep working on their own.
        settings.codexIncludeOpenCodeLocalHistory = false
        settings.codexLocalSessionCostLedgerEnabled = true
        #expect(settings.isHistoryLaneEffectivelyEnabled(for: .codex))
        settings.codexLocalSessionCostLedgerEnabled = false
        #expect(!settings.isHistoryLaneEffectivelyEnabled(for: .codex))
    }

    @Test
    func `codex settings expose the opencode opt-in toggle default off`() throws {
        let fixture = try self.makeSettingsFixture(suite: "OpenCodeLocalHistorySettingsTests-toggle")
        let context = fixture.settingsContext(provider: .codex)
        let toggle = try #require(CodexProviderImplementation().settingsToggles(context: context)
            .first(where: { $0.id == "codex-opencode-local-history" }))
        #expect(!toggle.binding.wrappedValue)
        toggle.binding.wrappedValue = true
        #expect(fixture.settings.codexIncludeOpenCodeLocalHistory)
        #expect(fixture.settings.isHistoryLaneEffectivelyEnabled(for: .codex))
    }

    @Test
    func `menu card exposes the codex cost section from the opencode opt-in alone`() throws {
        let fixture = try self.makeSettingsFixture(suite: "OpenCodeLocalHistorySettingsTests-menu")
        // Default-off with no other cost source: the ambient history lane stays hidden.
        #expect(!fixture.settings.costUsageEnabled)
        #expect(!fixture.settings.codexLocalSessionCostLedgerEnabled)
        #expect(!fixture.store.menuCardInput(for: .codex, context: .menu).tokenCostUsageEnabled)
        #expect(!fixture.store.menuCardInput(for: .codex, context: .menu).tokenCostMenuSectionEnabled)

        // The opt-in alone surfaces the menu-history lane for a user whose only source is
        // OpenCode — no second cost toggle required.
        fixture.settings.codexIncludeOpenCodeLocalHistory = true
        #expect(fixture.store.menuCardInput(for: .codex, context: .menu).tokenCostUsageEnabled)
        #expect(fixture.store.menuCardInput(for: .codex, context: .menu).tokenCostMenuSectionEnabled)
        #expect(fixture.store.menuCardInput(for: .codex, context: .settings).tokenCostMenuSectionEnabled)

        // Other providers never activate through this opt-in.
        #expect(!fixture.store.menuCardInput(for: .claude, context: .menu).tokenCostUsageEnabled)
        #expect(!fixture.store.menuCardInput(for: .claude, context: .menu).tokenCostMenuSectionEnabled)
    }

    private func makeSettingsFixture(suite: String) throws -> Fixture {
        let settings = testSettingsStore(suiteName: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        settings._test_managedCodexAccountStoreURL = root.appendingPathComponent("accounts.json")
        let environment = ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("codex").path]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        return Fixture(settings: settings, store: store)
    }

    private struct Fixture {
        let settings: SettingsStore
        let store: UsageStore
        private let state = ProviderSettingsContextState()

        @MainActor
        func settingsContext(provider: UsageProvider) -> ProviderSettingsContext {
            let settings = self.settings
            let store = self.store
            let state = self.state
            return ProviderSettingsContext(
                provider: provider,
                settings: settings,
                store: store,
                statusText: { id in state.statusByID[id] },
                setStatusText: { id, text in
                    if let text {
                        state.statusByID[id] = text
                    } else {
                        state.statusByID.removeValue(forKey: id)
                    }
                },
                lastAppActiveRunAt: { id in state.lastRunAtByID[id] },
                setLastAppActiveRunAt: { id, date in
                    if let date {
                        state.lastRunAtByID[id] = date
                    } else {
                        state.lastRunAtByID.removeValue(forKey: id)
                    }
                },
                requestConfirmation: { _ in },
                runLoginFlow: {})
        }
    }

    private final class ProviderSettingsContextState {
        var statusByID: [String: String] = [:]
        var lastRunAtByID: [String: Date] = [:]
    }
}
