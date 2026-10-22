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

    @Test
    func `inline summary style renders from the opencode opt-in alone`() throws {
        let fixture = try self.makeSettingsFixture(suite: "OpenCodeLocalHistorySettingsTests-inline")
        fixture.settings.costSummaryDisplayStyle = .inlineSummary
        // Default-off with no other cost source: the inline lane stays hidden.
        #expect(!fixture.settings.costSummaryShowsInline(for: .codex))

        // The opt-in alone renders the inline summary — the only presentation under this
        // style, since .inlineSummary disables the submenu.
        fixture.settings.codexIncludeOpenCodeLocalHistory = true
        #expect(fixture.settings.costSummaryShowsInline(for: .codex))
        #expect(!fixture.settings.costSummaryShowsSubmenu(for: .codex))
        #expect(fixture.store.menuCardInput(for: .codex, context: .menu).costSummaryInlineEnabled)

        // Other providers never activate through this opt-in.
        #expect(!fixture.settings.costSummaryShowsInline(for: .claude))
    }

    @Test
    func `opencode opt-in selects the ambient scope over the managed account home`() throws {
        let fixture = try self.makeSettingsFixture(suite: "OpenCodeLocalHistorySettingsTests-scope")
        fixture.settings._test_activeManagedCodexRemoteHomePath = "/tmp/managed-codex-home"
        fixture.settings.codexActiveSource = .managedAccount(id: UUID())
        defer { fixture.settings._test_activeManagedCodexRemoteHomePath = nil }

        // Default-off: the managed home stays selected and the merge stays gated off.
        let managedScope = fixture.store.tokenCostScope(for: .codex)
        #expect(managedScope.codexHomePath == "/tmp/managed-codex-home")
        #expect(!fixture.store.shouldIncludeOpenCodeLocalHistoryInTokenSnapshot(for: .codex))

        // The opt-in selects the ambient home — the machine-local scope its rows live in —
        // mirroring the local ledger, so the merge gate opens instead of scanning a home
        // whose scoped rows can never include OpenCode history.
        fixture.settings.codexIncludeOpenCodeLocalHistory = true
        let ambientScope = fixture.store.tokenCostScope(for: .codex)
        #expect(ambientScope.codexHomePath == nil)
        #expect(ambientScope.signature == "codex:ambient")
        #expect(fixture.store.shouldIncludeOpenCodeLocalHistoryInTokenSnapshot(for: .codex))
    }

    @Test
    func `ambient opencode publication survives codex account switches`() throws {
        let fixture = try self.makeSettingsFixture(suite: "OpenCodeLocalHistorySettingsTests-account")
        let store = fixture.store

        // The opt-in selects the ambient scope; a publication under that scope installs.
        store.settings.codexIncludeOpenCodeLocalHistory = true
        store.installCachedTokenSnapshot(Self.snapshot(cost: 1), for: .codex)
        #expect(store.accountScopedTokenSnapshot(for: .codex) != nil)

        // An account switch bumps the provider-config revision, but ambient history is
        // account-agnostic: the still-current ambient publication must not be discarded
        // or the This Mac section would vanish behind a rescan.
        let revisionBefore = store.settings.providerConfigRevision(for: .codex)
        store.settings.codexActiveSource = .managedAccount(id: UUID())
        #expect(store.settings.providerConfigRevision(for: .codex) != revisionBefore)
        #expect(store.accountScopedTokenSnapshot(for: .codex) != nil)

        // A pre-toggle scoped publication must not leak account rows into the ambient lane.
        store.settings.codexIncludeOpenCodeLocalHistory = false
        store.settings._test_activeManagedCodexRemoteHomePath = "/tmp/managed-codex-home"
        store.settings.codexActiveSource = .managedAccount(id: UUID())
        store.installCachedTokenSnapshot(Self.snapshot(cost: 2), for: .codex)
        store.settings.codexIncludeOpenCodeLocalHistory = true
        #expect(store.accountScopedTokenSnapshot(for: .codex) == nil)
    }

    private static func snapshot(cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [],
            updatedAt: Date())
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
