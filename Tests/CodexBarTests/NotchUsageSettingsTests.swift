import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct NotchUsageSettingsTests {
    @Test
    func `notch usage summary defaults off and persists`() throws {
        let fixture = try Self.makeFixture("persist")

        #expect(fixture.store.notchUsageSummaryEnabled == false)
        fixture.store.notchUsageSummaryEnabled = true

        #expect(try Self.reload(fixture).notchUsageSummaryEnabled)
    }

    @Test
    func `column count defaults to one and clamps out-of-range values`() throws {
        let fixture = try Self.makeFixture("columns")
        let store = fixture.store

        #expect(store.notchColumnCount == 1)

        store.notchColumnCount = 99
        #expect(store.notchColumnCount == SettingsStore.notchMaxColumnCount)

        store.notchColumnCount = 0
        #expect(store.notchColumnCount == 1)

        store.notchColumnCount = 3
        #expect(try Self.reload(fixture).notchColumnCount == 3)
    }

    @Test
    func `providers are opt out so new providers appear without revisiting settings`() throws {
        let fixture = try Self.makeFixture("providers")
        let store = fixture.store

        #expect(store.isNotchProviderVisible(.codex))
        #expect(store.isNotchProviderVisible(.claude))

        store.setNotchProviderVisible(.codex, visible: false)
        #expect(!store.isNotchProviderVisible(.codex))
        #expect(store.isNotchProviderVisible(.claude))

        let reloaded = try Self.reload(fixture)
        #expect(!reloaded.isNotchProviderVisible(.codex))
        reloaded.setNotchProviderVisible(.codex, visible: true)
        #expect(reloaded.isNotchProviderVisible(.codex))
    }

    @Test
    func `stored order applies and unknown keys keep their natural position`() throws {
        let fixture = try Self.makeFixture("order")
        let store = fixture.store

        // No stored order: incoming order is preserved.
        #expect(store.notchOrderedItemKeys(["codex", "claude"]) == ["codex", "claude"])

        store.setNotchItemOrder(["claude", "zai", "codex"])

        // Stored keys lead in stored order; anything new lands after them, in its own order.
        #expect(store.notchOrderedItemKeys(["codex", "claude", "zai", "cursor"])
            == ["claude", "zai", "codex", "cursor"])
        // Keys that are not currently available drop out instead of leaving a gap.
        #expect(store.notchOrderedItemKeys(["codex", "cursor"]) == ["codex", "cursor"])

        #expect(try Self.reload(fixture).notchItemOrder == ["claude", "zai", "codex"])
    }

    @Test
    func `agent session band is omitted until both switches are on`() throws {
        let settings = testSettingsStore(suiteName: "NotchUsageSettingsTests-sessions")
        let usageStore = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let sessions = AgentSessionsStore(settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        settings.agentSessionsEnabled = true
        sessions.applyLocalScanResult([
            AgentSession(
                id: "session-1",
                provider: .codex,
                source: .cli,
                state: .active,
                pid: 42,
                cwd: "/tmp/demo",
                projectName: "demo",
                startedAt: now.addingTimeInterval(-600),
                lastActivityAt: now.addingTimeInterval(-120),
                transcriptPath: nil,
                host: "local"),
        ])

        let hidden = NotchUsageOverlayModel.make(
            store: usageStore,
            settings: settings,
            agentSessions: sessions,
            now: now)
        #expect(hidden.sessionsBand == nil)

        settings.notchShowsAgentSessions = true
        let shown = NotchUsageOverlayModel.make(
            store: usageStore,
            settings: settings,
            agentSessions: sessions,
            now: now)
        // `items` is typed to provider rows, so the band cannot join the grid by construction.
        let band = try #require(shown.sessionsBand)
        let rows = band.rows
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.title == "demo")
        #expect(row.isActive)
        #expect(row.detail == "codex · 2m")
    }

    @Test
    func `tiles fill columns left to right in list order`() {
        let items: [NotchUsageOverlayModel.ProviderRow] = [
            Self.row(.codex),
            Self.row(.claude),
            Self.row(.cursor),
            Self.row(.gemini),
            Self.row(.zai),
        ]

        let single = NotchUsageOverlayModel(items: items, columnCount: 1).columns()
        #expect(single.count == 1)
        #expect(single[0].map(\.id) == [.codex, .claude, .cursor, .gemini, .zai])

        let double = NotchUsageOverlayModel(items: items, columnCount: 2).columns()
        #expect(double.count == 2)
        #expect(double[0].map(\.id) == [.codex, .cursor, .zai])
        #expect(double[1].map(\.id) == [.claude, .gemini])

        // An empty column is still returned so the layout keeps its requested shape.
        let sparse = NotchUsageOverlayModel(items: [items[0]], columnCount: 3).columns()
        #expect(sparse.map(\.count) == [1, 0, 0])
    }

    @Test
    func `dragging a row inserts it in front of its drop target`() {
        let keys = ["codex", "claude", "gemini", "cursor"]

        // Downward: the moved key lands where the target was.
        #expect(NotchPane.reordered(keys, moving: "codex", before: "cursor")
            == ["claude", "gemini", "codex", "cursor"])
        // Upward, including onto the first row.
        #expect(NotchPane.reordered(keys, moving: "gemini", before: "codex")
            == ["gemini", "codex", "claude", "cursor"])

        // A drop on itself, or a payload that is not one of these rows, changes nothing.
        #expect(NotchPane.reordered(keys, moving: "codex", before: "codex") == nil)
        #expect(NotchPane.reordered(keys, moving: "some dragged text", before: "codex") == nil)
        #expect(NotchPane.reordered(keys, moving: "codex", before: "not-a-row") == nil)
    }

    @Test
    func `each section has its own height ceiling, defaulted and clamped`() throws {
        let fixture = try Self.makeFixture("sizing")
        let store = fixture.store

        #expect(store.notchMatchesRowHeights)
        #expect(store.notchProvidersMaxHeight == SettingsStore.notchDefaultProvidersHeight)
        #expect(store.notchSessionsMaxHeight == SettingsStore.notchDefaultSessionsHeight)

        store.notchProvidersMaxHeight = 10
        #expect(store.notchProvidersMaxHeight == SettingsStore.notchMinSectionHeight)
        store.notchSessionsMaxHeight = 99999
        #expect(store.notchSessionsMaxHeight == SettingsStore.notchMaxSectionHeight)

        store.notchMatchesRowHeights = false
        store.notchProvidersMaxHeight = 640
        store.notchSessionsMaxHeight = 240

        let reloaded = try Self.reload(fixture)
        #expect(!reloaded.notchMatchesRowHeights)
        // The two ceilings are independent.
        #expect(reloaded.notchProvidersMaxHeight == 640)
        #expect(reloaded.notchSessionsMaxHeight == 240)
    }

    @Test
    func `sessions placement defaults to below and offers only the two sides`() throws {
        let fixture = try Self.makeFixture("placement")
        let store = fixture.store

        #expect(store.notchSessionsPlacement == .below)
        #expect(NotchSessionsPlacement.allCases == [.above, .below])

        store.notchSessionsPlacement = .above
        let reloaded = try Self.reload(fixture)
        #expect(reloaded.notchSessionsPlacement == .above)
    }

    @Test
    func `a session band spreads its rows over the grid column count`() {
        let rows = (1...5).map {
            NotchUsageOverlayModel.SessionRow(id: "s\($0)", title: "s\($0)", detail: "", isActive: true)
        }

        // Same round-robin the tile grid uses, so the band reads across rather than down one side.
        #expect(NotchUsageOverlayModel.distribute(rows, into: 3).map { $0.map(\.id) } == [
            ["s1", "s4"],
            ["s2", "s5"],
            ["s3"],
        ])
        #expect(NotchUsageOverlayModel.distribute(rows, into: 1).map(\.count) == [5])
        // A nonsense count still yields one usable column.
        #expect(NotchUsageOverlayModel.distribute(rows, into: 0).map(\.count) == [5])
    }

    @Test
    func `grid rows hold the tiles that share a row`() {
        let items: [NotchUsageOverlayModel.ProviderRow] = [
            Self.row(.codex),
            Self.row(.claude),
            Self.row(.cursor),
            Self.row(.zai),
            Self.row(.gemini),
        ]
        let model = NotchUsageOverlayModel(items: items, columnCount: 2)

        // Same placement as `columns()`, sliced the other way: only the last row is short.
        #expect(model.rows().map { $0.map(\.id) } == [
            [.codex, .claude],
            [.cursor, .zai],
            [.gemini],
        ])
        #expect(model.columns().map { $0.map(\.id) } == [
            [.codex, .cursor, .gemini],
            [.claude, .zai],
        ])
    }

    @Test
    func `the sessions band sits on the configured side`() throws {
        let settings = testSettingsStore(suiteName: "NotchUsageSettingsTests-band")
        let usageStore = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let sessions = AgentSessionsStore(settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        settings.agentSessionsEnabled = true
        settings.notchShowsAgentSessions = true
        sessions.applyLocalScanResult([
            AgentSession(
                id: "session-1",
                provider: .codex,
                source: .cli,
                state: .active,
                pid: 42,
                cwd: "/tmp/demo",
                projectName: "demo",
                startedAt: now.addingTimeInterval(-600),
                lastActivityAt: now.addingTimeInterval(-120),
                transcriptPath: nil,
                host: "local"),
        ])

        for (placement, expectAbove) in [(NotchSessionsPlacement.above, true), (.below, false)] {
            settings.notchSessionsPlacement = placement
            let model = NotchUsageOverlayModel.make(
                store: usageStore, settings: settings, agentSessions: sessions, now: now)
            let band = try #require(model.sessionsBand)
            #expect(!band.rows.isEmpty)
            #expect(model.sessionsAbove == expectAbove)
        }

        // Switched off, the band disappears entirely.
        settings.notchShowsAgentSessions = false
        let off = NotchUsageOverlayModel.make(
            store: usageStore, settings: settings, agentSessions: sessions, now: now)
        #expect(off.sessionsBand == nil)
    }

    private static func row(_ id: ProviderInstanceID) -> NotchUsageOverlayModel.ProviderRow {
        NotchUsageOverlayModel.ProviderRow(
            id: id,
            name: id.rawValue,
            tint: .green,
            bars: [],
            statusText: nil)
    }

    private struct Fixture {
        let defaults: UserDefaults
        let configStore: CodexBarConfigStore
        let store: SettingsStore
    }

    private static func makeFixture(_ name: String) throws -> Fixture {
        let suite = "NotchUsageSettingsTests-\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return Fixture(
            defaults: defaults,
            configStore: configStore,
            store: SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: NoopZaiTokenStore(),
                syntheticTokenStore: NoopSyntheticTokenStore()))
    }

    private static func reload(_ fixture: Fixture) throws -> SettingsStore {
        SettingsStore(
            userDefaults: fixture.defaults,
            configStore: fixture.configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
