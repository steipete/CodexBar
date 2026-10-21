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
    func `notch activation token changes only with feature enablement`() throws {
        let fixture = try Self.makeFixture("activation-token")
        let store = fixture.store
        let initial = store.notchActivationObservationToken

        store.notchColumnCount = 3
        store.notchProvidersMaxHeight = 720
        #expect(store.notchActivationObservationToken == initial)

        store.notchUsageSummaryEnabled = true
        #expect(store.notchActivationObservationToken == initial &+ 1)

        // A no-op assignment neither persists noise nor wakes the controller again.
        store.notchUsageSummaryEnabled = true
        #expect(store.notchActivationObservationToken == initial &+ 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `shortcut handlers exist only while enabled and are removed across restarts`() async throws {
        let fixture = try Self.makeFixture("shortcut-lifecycle")
        let settings = fixture.store
        let usageStore = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let (events, continuation) = AsyncStream<Void>.makeStream()
        var active = false
        var installs = 0
        var screenLookups = 0
        let controller = NotchUsageOverlayController(
            store: usageStore,
            settings: settings,
            notchedScreen: { screenLookups += 1; return nil },
            hotkeyRegistration: NotchHotkeyRegistration(
                install: { _, _ in
                    active = true
                    installs += 1
                    continuation.yield(())
                },
                remove: { active = false }))
        defer { controller.stop(); continuation.finish() }

        controller.start()
        #expect(!active)
        #expect(installs == 0)
        #expect(screenLookups == 0)

        var iterator = events.makeAsyncIterator()
        settings.notchUsageSummaryEnabled = true
        _ = await iterator.next()
        #expect(active)
        #expect(installs == 1)

        controller.stop()
        #expect(!active)
        controller.start()
        #expect(active)
        #expect(installs == 2)
        controller.stop()
        #expect(!active)
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
    func `agent session band can be enabled independently of the menu`() throws {
        let settings = testSettingsStore(
            suiteName: "NotchUsageSettingsTests-sessions",
            userDefaults: InMemoryUserDefaults())
        let usageStore = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let sessions = AgentSessionsStore(settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        settings.notchUsageSummaryEnabled = true
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

        settings.notchShowsAgentSessions = false
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
        #expect(!settings.agentSessionsEnabled)
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
            NotchUsageOverlayModel.SessionRow(
                id: "s\($0)",
                title: "s\($0)",
                detail: "",
                isActive: true,
                harness: "Codex")
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
    func `Codex extra usage fills only an otherwise empty slot`() throws {
        let settings = testSettingsStore(
            suiteName: "NotchUsageSettingsTests-credit-fallback",
            userDefaults: InMemoryUserDefaults())
        settings.providerEnablement[.codex] = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.credits = CreditsSnapshot(
            remaining: 80,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 20, limit: 100, remainingPercent: 80, resetsAt: nil, updatedAt: now))
        let primary = RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        func projectedBars(_ snapshot: UsageSnapshot) throws -> [NotchUsageOverlayModel.Bar] {
            store._setSnapshotForTesting(snapshot, provider: .codex)
            return try #require(NotchUsageOverlayModel.make(store: store, settings: settings, now: now)
                .items.first { $0.id == .codex }).bars
        }
        let withExtra = try projectedBars(UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: [NamedRateWindow(id: "team", title: "Team", window: primary)],
            updatedAt: now))
        #expect(withExtra.count == 3)
        #expect(withExtra.last?.title == "Team")

        let snapshot = UsageSnapshot(primary: primary, secondary: secondary, updatedAt: now)
        let fallback = try projectedBars(snapshot)
        let sharedCost = try #require(store.menuCardModel(for: .codex, now: now).providerCost)
        #expect(fallback.count == 3)
        #expect(fallback.last?.title == sharedCost.title)
        #expect(fallback.last?.percent == 80)
        #expect(fallback.last?.resetText == sharedCost.spendLine)

        settings.showOptionalCreditsAndExtraUsage = false
        #expect(try projectedBars(snapshot).count == 2)
    }

    @Test
    func `the sessions band sits on the configured side`() throws {
        let settings = testSettingsStore(
            suiteName: "NotchUsageSettingsTests-band",
            userDefaults: InMemoryUserDefaults())
        let usageStore = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
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

    @Test
    func `overlay follows shared hidden metrics and reset display`() throws {
        let settings = testSettingsStore(
            suiteName: "NotchUsageSettingsTests-shared-presentation",
            userDefaults: InMemoryUserDefaults(),
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true)]))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: now), provider: .claude)
        settings.setUsageItemVisible(false, itemID: .metric("primary"), for: .claude)
        let expected = store.menuCardModel(for: .claude, now: now)
        let row = try #require(NotchUsageOverlayModel.make(store: store, settings: settings, now: now)
            .items.first { $0.id == .claude })
        #expect(row.bars.map(\.title) == expected.metrics.map(\.title))
        #expect(row.bars.map(\.resetText) == expected.metrics.map(\.resetText))
    }

    @Test
    func `notch header prioritizes available reset credits and respects hidden providers and usage items`() {
        let settings = testSettingsStore(
            suiteName: "NotchUsageSettingsTests-header",
            userDefaults: InMemoryUserDefaults(),
            config: CodexBarConfig(providers: [
                ProviderConfig(id: .claude, enabled: true),
                ProviderConfig(id: .codex, enabled: true),
            ]))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let credits = [172_800.0, -1.0].enumerated().map { index, expiry in
            CodexRateLimitResetCredit(
                id: "fixture-\(index)",
                resetType: "codex_rate_limits",
                status: .available,
                grantedAt: now.addingTimeInterval(-7200),
                expiresAt: now.addingTimeInterval(expiry),
                redeemStartedAt: nil,
                redeemedAt: nil,
                title: nil,
                description: nil)
        }
        store._setSnapshotForTesting(UsageSnapshot(
            primary: nil,
            secondary: window,
            codexResetCredits: CodexRateLimitResetCreditsSnapshot(
                credits: credits, availableCount: 1, updatedAt: now),
            updatedAt: now), provider: .codex)
        store._setSnapshotForTesting(UsageSnapshot(primary: nil, secondary: window, updatedAt: now), provider: .claude)
        settings.setNotchItemOrder(["claude", "codex"])

        settings.resetTimesShowAbsolute = true
        let model = NotchUsageOverlayModel.make(store: store, settings: settings, now: now)
        let header = model.headerItems
        #expect(header.map(\.id) == ["codex:reset-credits", "claude:secondary", "codex:secondary"])
        #expect(header[0].value == "1 available")
        #expect(header[0].accessibilityLabel.contains("Codex"))
        #expect(header[1].value == "75% left")
        #expect(header[0].expiryText == "Expires in 2d")
        #expect(model.earItem(selection: "", automaticIndex: 0)?.id == "codex:reset-credits")
        #expect(model.earItem(selection: "", automaticIndex: 1)?.id == "claude:secondary")
        #expect(model.earItem(selection: "codex:secondary", automaticIndex: 0)?.provider == .codex)
        #expect(model.earItem(selection: "missing:primary", automaticIndex: 0) == nil)
        #expect(model.earItem(selection: "", automaticIndex: 99) == nil)

        settings.setUsageItemVisible(false, itemID: .codexResetCredits, for: .codex)
        let hiddenCredits = NotchUsageOverlayModel.make(store: store, settings: settings, now: now).headerItems
        #expect(NotchUsageOverlayModel.make(store: store, settings: settings, now: now)
            .earItem(selection: "codex:reset-credits", automaticIndex: 0) == nil)
        #expect(hiddenCredits.map(\.id) == ["claude:secondary", "codex:secondary"])
        settings.setNotchProviderVisible(.codex, visible: false)
        #expect(NotchUsageOverlayModel.make(store: store, settings: settings, now: now).headerItems
            .map(\.provider) == [.claude])
        settings.setUsageItemVisible(false, itemID: .metric("secondary"), for: .claude)
        #expect(NotchUsageOverlayModel.make(store: store, settings: settings, now: now).headerItems.isEmpty)
    }

    @Test
    func `ears visibility and each content selection persist independently of the main notch`() throws {
        let fixture = try Self.makeFixture("ears")
        let settings = fixture.store
        #expect(settings.notchShowsEars)
        #expect(settings.notchLeftEarContent.isEmpty)
        #expect(settings.notchRightEarContent.isEmpty)
        settings.notchUsageSummaryEnabled = true
        settings.notchShowsEars = false
        settings.notchLeftEarContent = "codex:reset-credits"
        settings.notchRightEarContent = "claude:secondary"
        let reloaded = try Self.reload(fixture)
        #expect(reloaded.notchUsageSummaryEnabled)
        #expect(!reloaded.notchShowsEars)
        #expect(reloaded.notchLeftEarContent == "codex:reset-credits")
        #expect(reloaded.notchRightEarContent == "claude:secondary")
        reloaded.notchShowsEars = true
        reloaded.notchUsageSummaryEnabled = false
        #expect(reloaded.notchShowsEars)
    }

    @Test
    func `session columns follow providers by default and persist independent choices`() throws {
        let fixture = try Self.makeFixture("session-columns")
        #expect(fixture.store.notchSessionsColumns == .matchProviders)
        fixture.store.notchSessionsColumns = .three
        fixture.store.notchColumnCount = 2
        #expect(try Self.reload(fixture).notchSessionsColumns == .three)
        fixture.store.notchSessionsColumns = .perHarness
        #expect(try Self.reload(fixture).notchSessionsColumns == .perHarness)
        fixture.defaults.set(99, forKey: "notchSessionsColumns")
        #expect(try Self.reload(fixture).notchSessionsColumns == .matchProviders)
    }

    @Test
    func `session columns group by harness or use independent counts`() throws {
        let settings = try Self.makeFixture("session-grouping").store
        settings.notchUsageSummaryEnabled = true
        settings.notchShowsAgentSessions = true
        settings.notchColumnCount = 2
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let sessions = AgentSessionsStore(settings: settings)
        let now = Date()
        let local = [AgentSession.Provider.codex, .claude, .pi, .pi].enumerated().map { index, provider in
            AgentSession(
                id: "session-\(index)",
                provider: provider,
                dialect: index == 3 ? .omp : nil,
                source: .cli,
                state: .active,
                pid: nil,
                cwd: nil,
                projectName: "Fixture \(index)",
                startedAt: now,
                lastActivityAt: now,
                transcriptPath: nil,
                host: "local")
        }
        sessions.applyLocalScanResult(local)
        let model = { NotchUsageOverlayModel.make(store: store, settings: settings, agentSessions: sessions) }
        #expect(model().sessionsBand?.columns.map(\.count) == [2, 2])
        settings.notchColumnCount = 1
        #expect(model().sessionsBand?.columns.count == 1)
        settings.notchSessionsColumns = .three
        #expect(model().sessionsBand?.columns.map(\.count) == [2, 1, 1])
        settings.notchColumnCount = 4
        #expect(model().sessionsBand?.columns.count == 3)
        settings.notchSessionsColumns = .perHarness
        let grouped = try #require(model().sessionsBand)
        #expect(grouped.groupedByHarness)
        #expect(grouped.columns.map { $0.map(\.harness) } == [["Claude"], ["Codex"], ["OMP"], ["Pi"]])
        var secondCodex = local[0]
        secondCodex.id = "another-codex"
        sessions.applyLocalScanResult([local[0], secondCodex])
        #expect(model().sessionsBand?.columns.count == 1)
        sessions.applyLocalScanResult([])
        #expect(model().sessionsBand?.columns.isEmpty == true)
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
        let store: SettingsStore
    }

    private static func makeFixture(_ name: String) throws -> Fixture {
        let defaults = InMemoryUserDefaults()
        return Fixture(
            defaults: defaults,
            store: testSettingsStore(suiteName: "NotchUsageSettingsTests-\(name)", userDefaults: defaults))
    }

    private static func reload(_ fixture: Fixture) throws -> SettingsStore {
        testSettingsStore(
            suiteName: "NotchUsageSettingsTests-reload",
            userDefaults: fixture.defaults,
            config: fixture.store.configSnapshot)
    }
}
