import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

@MainActor
struct OpenCodeWidgetSnapshotTests {
    @Test
    func widgetSnapshotEmitsOneSafeEntryPerSavedWorkspace() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = Self.makeSettingsStore(suite: "OpenCodeWidgetSnapshotTests-entries")
        settings.addTokenAccount(provider: .opencode, label: "Shared", token: "auth=shared")
        let tokenAccount = try #require(settings.selectedTokenAccount(for: .opencode))
        #expect(settings.addOpenCodeWorkspace(
            tokenAccountID: tokenAccount.id,
            workspaceID: "wrk_ALPHA",
            label: "Alpha",
            ownerLabel: "Alice") == .saved)
        #expect(settings.addOpenCodeWorkspace(
            tokenAccountID: tokenAccount.id,
            workspaceID: "wrk_BETA",
            label: "Beta",
            ownerLabel: "Bob") == .saved)
        let accounts = settings.opencodeWorkspaceAccounts.accounts
        let store = Self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .opencode)
        store.openCodeWorkspaceSnapshots[accounts[1].id] = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: now)

        var captured: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { captured = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "opencode-workspaces")
        await store.widgetSnapshotPersistTask?.value

        let entries = captured?.entries.filter { $0.provider == .opencode } ?? []
        #expect(entries.count == 2)
        #expect(entries.map(\.accountLabel) == ["Alpha · Alice", "Beta · Bob"])
        #expect(entries.map(\.accountID) == accounts.map(\.id))
        let encoded = try JSONEncoder().encode(captured)
        let encodedText = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!encodedText.contains("auth=shared"))
    }

    @Test
    func widgetSelectionUsesRequestedWorkspaceAndFallsBackSafely() {
        let first = WidgetSnapshot.ProviderEntry(
            provider: .opencode,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            accountID: "first",
            accountLabel: "First",
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let second = WidgetSnapshot.ProviderEntry(
            provider: .opencode,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            accountID: "second",
            accountLabel: "Second",
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [first, second], generatedAt: Date())

        #expect(snapshot.entry(for: .opencode, accountID: "second")?.accountLabel == "Second")
        #expect(snapshot.entry(for: .opencode, accountID: "deleted")?.accountLabel == "First")
    }

    @Test
    func openCodeIntentAcceptsOnlySnapshotWorkspaceIDs() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .opencode,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            accountID: "canonical",
            accountLabel: "Safe",
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], generatedAt: Date())

        #expect(SwitchWidgetOpenCodeWorkspaceIntent.validatedAccountID("canonical", snapshot: snapshot) == nil)
        #expect(SwitchWidgetOpenCodeWorkspaceIntent.validatedAccountID("deleted", snapshot: snapshot) == nil)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }
}
