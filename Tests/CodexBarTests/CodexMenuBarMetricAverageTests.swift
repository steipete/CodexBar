import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexMenuBarMetricAverageTests {
    @Test
    func `average window is nil for empty inputs`() {
        let window = CodexMenuBarMetricAverage.averageWindow(active: nil, imported: [])

        #expect(window == nil)
    }

    @Test
    func `average window keeps active only value`() throws {
        let active = Self.window(usedPercent: 37)

        let window = try #require(CodexMenuBarMetricAverage.averageWindow(active: active, imported: []))

        #expect(window.usedPercent == 37)
        #expect(window.windowMinutes == 300)
    }

    @Test
    func `average window averages imported only values`() throws {
        let window = try #require(CodexMenuBarMetricAverage.averageWindow(
            active: nil,
            imported: [
                Self.window(usedPercent: 20),
                Self.window(usedPercent: 80),
            ]))

        #expect(window.usedPercent == 50)
    }

    @Test
    func `average window averages active and imported values`() throws {
        let window = try #require(CodexMenuBarMetricAverage.averageWindow(
            active: Self.window(usedPercent: 10),
            imported: [
                Self.window(usedPercent: 40),
                Self.window(usedPercent: 70),
            ]))

        #expect(window.usedPercent == 40)
    }

    @MainActor
    @Test
    func `menu bar icon averages primary and secondary lanes for active and imported codex snapshots`() {
        let store = Self.makeStore(suite: "CodexMenuBarMetricAverageTests-icon-mixed")
        let active = Self.snapshot(primary: 20, secondary: 40)
        store.importedCodexAccountSnapshots = [
            Self.importedCodexSnapshot(id: "borrowed:one:path", primary: 80, secondary: 60),
            Self.importedCodexSnapshot(id: "borrowed:two:path", primary: 50, secondary: 100),
        ]

        let percents = store.menuBarIconPercents(for: .codex, snapshot: active, style: .codex, showUsed: true)

        #expect(abs((percents.primary ?? -1) - 50) < 0.0001)
        #expect(abs((percents.secondary ?? -1) - 66.66666666666667) < 0.0001)
    }

    @MainActor
    @Test
    func `menu bar icon averages primary and secondary lanes for imported only codex snapshots`() {
        let store = Self.makeStore(suite: "CodexMenuBarMetricAverageTests-icon-imported-only")
        store.importedCodexAccountSnapshots = [
            Self.importedCodexSnapshot(id: "borrowed:one:path", primary: 30, secondary: 40),
            Self.importedCodexSnapshot(id: "borrowed:two:path", primary: 90, secondary: 80),
        ]

        let percents = store.menuBarIconPercents(for: .codex, snapshot: nil, style: .codex, showUsed: true)

        #expect(percents.primary == 60)
        #expect(percents.secondary == 60)
    }

    @MainActor
    @Test
    func `menu bar icon secondary average ignores codex snapshots without weekly lane`() {
        let store = Self.makeStore(suite: "CodexMenuBarMetricAverageTests-icon-missing-weekly")
        let active = Self.snapshot(primary: 30, secondary: 60)
        store.importedCodexAccountSnapshots = [
            Self.importedCodexSnapshot(id: "borrowed:one:path", primary: 90, secondary: nil),
            Self.importedCodexSnapshot(id: "borrowed:two:path", primary: 60, secondary: 30),
        ]

        let percents = store.menuBarIconPercents(for: .codex, snapshot: active, style: .codex, showUsed: true)

        #expect(percents.primary == 60)
        #expect(percents.secondary == 45)
    }

    private static func window(usedPercent: Double) -> RateWindow {
        RateWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
    }

    @MainActor
    private static func makeStore(suite: String) -> UsageStore {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        return UsageStore(fetcher: UsageFetcher(), browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
    }

    private static func snapshot(primary: Double, secondary: Double?) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: primary, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: secondary.map {
                RateWindow(usedPercent: $0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
            },
            updatedAt: Date())
    }

    private static func importedCodexSnapshot(
        id: String,
        primary: Double,
        secondary: Double?)
        -> ImportedCodexAccountUsageSnapshot
    {
        ImportedCodexAccountUsageSnapshot(
            account: BorrowedCodexAccount(
                id: id,
                email: "\(id)@example.com",
                accountId: id,
                credentials: CodexOAuthCredentials(
                    accessToken: "access-token",
                    refreshToken: "refresh-token",
                    idToken: nil,
                    accountId: id,
                    lastRefresh: nil),
                expired: nil,
                isExpired: false,
                sourcePath: "/tmp/\(id).json"),
            snapshot: Self.snapshot(primary: primary, secondary: secondary),
            error: nil,
            sourceLabel: "borrowed")
    }
}
