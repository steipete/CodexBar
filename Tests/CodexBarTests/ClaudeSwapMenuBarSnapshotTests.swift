import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Regression coverage for issue #2731: with two (or more) claude-swap accounts the
/// menu showed real per-account usage while the menu-bar indicator kept rendering the
/// ambient Claude snapshot, which can have no usable windows. The menu-bar presentation
/// snapshot must follow the active claude-swap account whenever the adapter owns Claude
/// account presentation, and keep the ambient snapshot as the fallback otherwise.
@MainActor
struct ClaudeSwapMenuBarSnapshotTests {
    @Test
    func `two swap accounts drive the menu bar from the active account snapshot`() throws {
        let store = Self.makeUsageStore(suite: "ClaudeSwapMenuBarSnapshotTests-two")
        store.claudeSwapAccountSnapshots = Self.swapAccounts(count: 2, activeNumber: 1)

        // The reported shape: adapter has usage for both accounts, ambient Claude has none.
        #expect(store.snapshot(for: .claude) == nil)
        let snapshot = try #require(store.menuBarSnapshot(for: UsageProvider.claude.instanceID))
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.secondary?.usedPercent == 60)
    }

    @Test
    func `two swap accounts win over a present ambient snapshot`() throws {
        let store = Self.makeUsageStore(suite: "ClaudeSwapMenuBarSnapshotTests-two-ambient")
        store.claudeSwapAccountSnapshots = Self.swapAccounts(count: 2, activeNumber: 2)
        store._setSnapshotForTesting(Self.ambientSnapshot(usedPercent: 99), provider: .claude)

        // The menu renders the adapter cards, so the bar must agree with the active card.
        let snapshot = try #require(store.menuBarSnapshot(for: UsageProvider.claude.instanceID))
        #expect(snapshot.primary?.usedPercent == 26)
    }

    @Test
    func `single swap account keeps the ambient snapshot without opt in`() throws {
        let store = Self.makeUsageStore(suite: "ClaudeSwapMenuBarSnapshotTests-one")
        store.claudeSwapAccountSnapshots = Self.swapAccounts(count: 1, activeNumber: 1)
        store._setSnapshotForTesting(Self.ambientSnapshot(usedPercent: 42), provider: .claude)

        let snapshot = try #require(store.menuBarSnapshot(for: UsageProvider.claude.instanceID))
        #expect(snapshot.primary?.usedPercent == 42)
    }

    @Test
    func `single swap account drives the menu bar when opted in`() throws {
        let store = Self.makeUsageStore(suite: "ClaudeSwapMenuBarSnapshotTests-one-optin")
        store.settings.claudeSwapShowSingleAccount = true
        store.claudeSwapAccountSnapshots = Self.swapAccounts(count: 1, activeNumber: 1)
        store._setSnapshotForTesting(Self.ambientSnapshot(usedPercent: 42), provider: .claude)

        let snapshot = try #require(store.menuBarSnapshot(for: UsageProvider.claude.instanceID))
        #expect(snapshot.primary?.usedPercent == 25)
    }

    @Test
    func `four swap accounts drive the menu bar from the active account snapshot`() throws {
        let store = Self.makeUsageStore(suite: "ClaudeSwapMenuBarSnapshotTests-four")
        store.claudeSwapAccountSnapshots = Self.swapAccounts(count: 4, activeNumber: 3)

        let snapshot = try #require(store.menuBarSnapshot(for: UsageProvider.claude.instanceID))
        #expect(snapshot.primary?.usedPercent == 27)
    }

    @Test
    func `active account without usable usage falls back to the ambient snapshot`() throws {
        let store = Self.makeUsageStore(suite: "ClaudeSwapMenuBarSnapshotTests-fallback")
        var rows = Self.swapRows(count: 2, activeNumber: 1)
        rows[0] = ClaudeSwapAccountRow(
            number: 1,
            email: "active@example.com",
            isActive: true,
            usageStatus: .tokenExpired,
            fiveHour: nil,
            sevenDay: nil,
            scoped: [])
        store.claudeSwapAccountSnapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(activeAccountNumber: 1, accounts: rows),
            now: Self.now)
        store._setSnapshotForTesting(Self.ambientSnapshot(usedPercent: 55), provider: .claude)

        let snapshot = try #require(store.menuBarSnapshot(for: UsageProvider.claude.instanceID))
        #expect(snapshot.primary?.usedPercent == 55)
    }

    @Test
    func `no swap accounts keeps the ambient snapshot`() throws {
        let store = Self.makeUsageStore(suite: "ClaudeSwapMenuBarSnapshotTests-none")
        store._setSnapshotForTesting(Self.ambientSnapshot(usedPercent: 33), provider: .claude)

        let snapshot = try #require(store.menuBarSnapshot(for: UsageProvider.claude.instanceID))
        #expect(snapshot.primary?.usedPercent == 33)
    }

    @Test
    func `swap accounts never override other providers`() throws {
        let store = Self.makeUsageStore(suite: "ClaudeSwapMenuBarSnapshotTests-other")
        store.claudeSwapAccountSnapshots = Self.swapAccounts(count: 2, activeNumber: 1)
        store._setSnapshotForTesting(Self.ambientSnapshot(usedPercent: 12), provider: .codex)

        let snapshot = try #require(store.menuBarSnapshot(for: UsageProvider.codex.instanceID))
        #expect(snapshot.primary?.usedPercent == 12)
    }

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    private static func swapAccounts(count: Int, activeNumber: Int) -> [ProviderAccountUsageSnapshot] {
        ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: activeNumber,
                accounts: self.swapRows(count: count, activeNumber: activeNumber)),
            now: self.now)
    }

    private static func swapRows(count: Int, activeNumber: Int) -> [ClaudeSwapAccountRow] {
        (1...count).map { number in
            ClaudeSwapAccountRow(
                number: number,
                email: "account\(number)@example.com",
                isActive: number == activeNumber,
                usageStatus: .ok,
                fiveHour: ClaudeSwapUsageWindow(
                    usedPercent: Double(24 + number),
                    resetsAt: self.now.addingTimeInterval(3600)),
                sevenDay: ClaudeSwapUsageWindow(
                    usedPercent: Double(59 + number),
                    resetsAt: self.now.addingTimeInterval(86400)),
                scoped: [])
        }
    }

    private static func ambientSnapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: self.now)
    }

    private static func makeUsageStore(suite: String) -> UsageStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
    }
}
