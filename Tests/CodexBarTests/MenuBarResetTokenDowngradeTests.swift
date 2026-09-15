import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarResetTokenDowngradeTests {
    @Test
    func `released V2 startup demonstrates why new reset cases need a new storage version`() throws {
        let fixture = self.fixture()
        let defaults = InMemoryUserDefaults()
        // Reproduce the original patch's writes to the released app's full-fidelity keys.
        try defaults.set(JSONEncoder().encode(fixture.layout), forKey: "menuBarLayoutV2")
        try defaults.set(JSONEncoder().encode(fixture.layout.legacyCompatible()), forKey: "menuBarLayout")
        try defaults.set(JSONEncoder().encode(fixture.overrides), forKey: "menuBarLayoutOverridesV2")
        let projected = fixture.overrides.mapValues { $0.legacyCompatible() }
        try defaults.set(JSONEncoder().encode(projected), forKey: "menuBarLayoutOverrides")

        let before = defaults.data(forKey: "menuBarLayoutV2")
        let loaded = try ReleasedResetV2.startup(defaults)
        #expect(loaded.layout == fixture.layout.legacyCompatible())
        #expect(loaded.layout?.lines.joined().contains(.conditional(id: fixture.retained.id)) == false)
        #expect(loaded.layout?.lines.joined().contains(.lanePercent(lane: .tertiary)) == false)
        #expect(defaults.data(forKey: "menuBarLayoutV2") != before)
        #expect(loaded.overrides == projected)
        #expect(loaded.overrides["claude"] != fixture.overrides["claude"])
    }

    @Test
    func `released startup and reupgrade retain new reset state and unrelated V2 placements`() throws {
        let fixture = self.fixture()
        let defaults = InMemoryUserDefaults()
        try self.save(fixture, into: defaults)
        let fullLayout = defaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent)
        let fullOverrides = defaults.data(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)
        let fullLibrary = defaults.data(forKey: MenuBarLayoutUserDefaultsKey.conditionalsCurrent)

        let released = try ReleasedResetV2.startup(defaults)
        #expect(released.layout == MenuBarLayout(lines: [[
            .icon, .lanePercent(lane: .tertiary), .conditional(id: fixture.retained.id),
        ]]))
        #expect(released.overrides["codex"] == MenuBarLayout(lines: [[.icon]]))
        #expect(released.overrides["claude"] == fixture.overrides["claude"])
        #expect(released.library == [fixture.retained])
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent) == fullLayout)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent) == fullOverrides)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.conditionalsCurrent) == fullLibrary)

        let upgraded = self.reload(defaults)
        #expect(upgraded.layout == fixture.layout)
        #expect(upgraded.overrides == fixture.overrides)
        #expect(upgraded.library == fixture.library)
    }

    @Test(arguments: [false, true])
    func `released edits win on reupgrade without erasing unrelated supported overrides`(deleteOverride: Bool) throws {
        let fixture = self.fixture()
        let defaults = InMemoryUserDefaults()
        try self.save(fixture, into: defaults)
        var released = try ReleasedResetV2.startup(defaults)
        released.layout = MenuBarLayout(lines: [[.providerName, .lanePercent(lane: .secondary)]])
        released.overrides["codex"] = deleteOverride ? nil : MenuBarLayout(lines: [[.accountLabel, .resetAbsolute]])
        released.library = []
        try ReleasedResetV2.save(released, into: defaults)

        let upgraded = self.reload(defaults)
        #expect(upgraded.layout == released.layout)
        #expect(upgraded.overrides == released.overrides)
        #expect(upgraded.overrides["claude"] == fixture.overrides["claude"])
        #expect(upgraded.library == [])
    }

    @Test(arguments: [false, true])
    func `editing one released override retains another provider full reset selection`(deleteOverride: Bool) throws {
        let base = self.fixture()
        let claude = MenuBarLayout(lines: [[.providerName, .windowResetCountdown(window: .weekly)]])
        let fixture = try Fixture(
            layout: base.layout,
            overrides: ["codex": #require(base.overrides["codex"]), "claude": claude],
            library: base.library,
            retained: base.retained)
        let defaults = InMemoryUserDefaults()
        try self.save(fixture, into: defaults)
        var released = try ReleasedResetV2.startup(defaults)
        let edited = MenuBarLayout(lines: [[.accountLabel, .resetAbsolute]])
        released.overrides["codex"] = deleteOverride ? nil : edited
        try ReleasedResetV2.save(released, into: defaults)
        let upgraded = self.reload(defaults)
        #expect(upgraded.overrides["codex"] == (deleteOverride ? nil : edited))
        #expect(upgraded.overrides["claude"] == claude)
    }

    @Test
    func `V2 startup upgrade materializes V3 before any editor write`() throws {
        let fixture = self.fixture()
        let defaults = InMemoryUserDefaults()
        let released = try ReleasedResetV2.State(
            layout: fixture.overrides["claude"],
            overrides: ["claude": #require(fixture.overrides["claude"])],
            library: [fixture.retained])
        try ReleasedResetV2.save(released, into: defaults)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent) == nil)
        let upgraded = self.reload(defaults)
        #expect(upgraded.layout == released.layout)
        #expect(upgraded.overrides == released.overrides)
        #expect(upgraded.library == released.library)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent) != nil)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent) != nil)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.conditionalsCurrent) != nil)
        let downgraded = try ReleasedResetV2.startup(defaults)
        #expect(downgraded.layout == released.layout)
        #expect(downgraded.overrides == released.overrides)
        #expect(downgraded.library == released.library)
    }

    @Test
    func `prestamp lanePace triple repairs to V3 and reprojects older keys`() throws {
        let monthly = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary), .lanePace(lane: .tertiary)]])
        let defaults = InMemoryUserDefaults()
        // The user's stranded state: V2/V1 written before releasedCompatible mapped lanePace
        // instead of filtering it, so the agreement gate falls back to V2 forever.
        try defaults.set(JSONEncoder().encode(["opencodego": monthly]), forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)
        try defaults.set(
            JSONEncoder().encode(["opencodego": MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary)]])]),
            forKey: "menuBarLayoutOverridesV2")
        try defaults.set(
            JSONEncoder().encode(["opencodego": MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])]),
            forKey: "menuBarLayoutOverrides")
        #expect(defaults.integer(forKey: MenuBarLayoutUserDefaultsKey.projectionVersionOverrides) == 0)

        let loaded = self.reload(defaults)
        #expect(loaded.overrides["opencodego"] == monthly)
        let released: [String: MenuBarLayout]? = self.decode(defaults.data(forKey: "menuBarLayoutOverridesV2"))
        #expect(released == ["opencodego": monthly.releasedCompatible()])
        #expect(released?["opencodego"]?.lines.joined().contains(.pace(window: .automatic)) == true)
        let legacy: [String: MenuBarLayout]? = self.decode(defaults.data(forKey: "menuBarLayoutOverrides"))
        #expect(legacy == released?.mapValues { $0.legacyCompatible(for: UsageProvider(rawValue: "opencodego")) })
        #expect(defaults.integer(forKey: MenuBarLayoutUserDefaultsKey.projectionVersionOverrides) == MenuBarLayoutPersistence.projectionVersion)
    }

    @Test
    func `layout load does not disarm overrides repair`() throws {
        // Loaders run layout first: a shared stamp let the global triple disarm repair for the
        // overrides triple. Stamps are per-triple, so seeding both prestamp must repair both.
        let monthly = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary), .lanePace(lane: .tertiary)]])
        let plain = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        let defaults = InMemoryUserDefaults()
        try defaults.set(JSONEncoder().encode(plain), forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent)
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(plain)
        try defaults.set(layoutBlobs.released, forKey: "menuBarLayoutV2")
        try defaults.set(layoutBlobs.legacy, forKey: "menuBarLayout")
        try defaults.set(JSONEncoder().encode(["opencodego": monthly]), forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)
        try defaults.set(
            JSONEncoder().encode(["opencodego": MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary)]])]),
            forKey: "menuBarLayoutOverridesV2")
        try defaults.set(
            JSONEncoder().encode(["opencodego": MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])]),
            forKey: "menuBarLayoutOverrides")
        #expect(defaults.integer(forKey: MenuBarLayoutUserDefaultsKey.projectionVersionLayout) == 0)
        #expect(defaults.integer(forKey: MenuBarLayoutUserDefaultsKey.projectionVersionOverrides) == 0)

        let loaded = self.reload(defaults)
        #expect(loaded.layout == plain)
        #expect(loaded.overrides["opencodego"] == monthly)
        #expect(defaults.integer(forKey: MenuBarLayoutUserDefaultsKey.projectionVersionLayout) == MenuBarLayoutPersistence.projectionVersion)
        #expect(defaults.integer(forKey: MenuBarLayoutUserDefaultsKey.projectionVersionOverrides) == MenuBarLayoutPersistence.projectionVersion)
    }

    @Test
    func `prestamp repair keeps older-only provider keys`() throws {
        let codex = MenuBarLayout(lines: [[.icon]])
        let claudeV2 = MenuBarLayout(lines: [[.providerName]])
        let defaults = InMemoryUserDefaults()
        try defaults.set(JSONEncoder().encode(["codex": codex]), forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)
        try defaults.set(
            JSONEncoder().encode(["codex": codex.releasedCompatible(), "claude": claudeV2]),
            forKey: "menuBarLayoutOverridesV2")
        try defaults.set(
            JSONEncoder().encode([
                "codex": codex.releasedCompatible().legacyCompatible(for: .codex),
                "claude": claudeV2.legacyCompatible(for: .claude),
            ]),
            forKey: "menuBarLayoutOverrides")

        let loaded = self.reload(defaults)
        #expect(loaded.overrides["codex"] == codex)
        #expect(loaded.overrides["claude"] == claudeV2)
    }

    @Test
    func `prestamp global layout repairs to V3`() throws {
        let monthly = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary), .lanePace(lane: .tertiary)]])
        let defaults = InMemoryUserDefaults()
        try defaults.set(JSONEncoder().encode(monthly), forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent)
        try defaults.set(
            JSONEncoder().encode(MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary)]])),
            forKey: "menuBarLayoutV2")
        try defaults.set(
            JSONEncoder().encode(MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary)]])),
            forKey: "menuBarLayout")

        let loaded = self.reload(defaults)
        #expect(loaded.layout == monthly)
        let released: MenuBarLayout? = self.decode(defaults.data(forKey: "menuBarLayoutV2"))
        #expect(released == monthly.releasedCompatible())
        #expect(defaults.integer(forKey: MenuBarLayoutUserDefaultsKey.projectionVersionLayout) == MenuBarLayoutPersistence.projectionVersion)
    }

    @Test
    func `stamped triple still honors a downgrade edit`() throws {
        let monthly = MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary), .lanePace(lane: .tertiary)]])
        let defaults = InMemoryUserDefaults()
        try defaults.set(JSONEncoder().encode(["opencodego": monthly]), forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)
        let blobs = try MenuBarLayoutPersistence.encodedOverrides(["opencodego": monthly])
        try defaults.set(blobs.released, forKey: "menuBarLayoutOverridesV2")
        try defaults.set(blobs.legacy, forKey: "menuBarLayoutOverrides")
        MenuBarLayoutPersistence.stampProjectionVersion(
            forKey: MenuBarLayoutUserDefaultsKey.projectionVersionOverrides, in: defaults)
        // An old release edits V2/V1 only and never touches the stamp.
        try defaults.set(
            JSONEncoder().encode(["opencodego": MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary)]])]),
            forKey: "menuBarLayoutOverridesV2")
        try defaults.set(
            JSONEncoder().encode(["opencodego": MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary)]])]),
            forKey: "menuBarLayoutOverrides")

        let loaded = self.reload(defaults)
        #expect(loaded.overrides["opencodego"] == MenuBarLayout(lines: [[.icon, .lanePercent(lane: .tertiary)]]))
    }

    @Test
    func `fresh defaults do not materialize saved layouts or an empty conditional library`() {
        let defaults = InMemoryUserDefaults()
        let loaded = self.reload(defaults)
        #expect(loaded.layout == nil)
        #expect(loaded.overrides.isEmpty)
        #expect(defaults.dictionaryRepresentation().isEmpty)
    }

    @Test(arguments: [false, true])
    func `released library edits preserve invisible reset rules unless an older ID replaces them`(
        replaceInvisibleID: Bool) throws
    {
        let fixture = self.fixture()
        let defaults = InMemoryUserDefaults()
        try self.save(fixture, into: defaults)
        var released = try ReleasedResetV2.startup(defaults)
        var edited = fixture.retained
        edited.name = "Edited on released build"
        edited.thenToken = .providerName
        let invisible = try #require(fixture.library.last)
        let replacement = MenuBarLayoutConditional(
            id: invisible.id,
            name: "Older rule with the same ID",
            clauses: fixture.retained.clauses,
            thenToken: .accountLabel,
            elseToken: .hidden)
        released.library = replaceInvisibleID ? [edited, replacement] : [edited]
        try ReleasedResetV2.save(released, into: defaults)

        let upgraded = self.reload(defaults)
        #expect(upgraded.library == [edited, replaceInvisibleID ? replacement : invisible])
        #expect(Set(upgraded.library.map(\.id)).count == upgraded.library.count)
    }

    private func fixture() -> Fixture {
        let retained = MenuBarLayoutConditional(
            clauses: [
                MenuBarConditionalClause(
                    combinator: nil,
                    predicate: MenuBarConditionalPredicate(
                        metric: .weekly, direction: .remaining, comparison: .greaterThan, threshold: 80)),
                MenuBarConditionalClause(
                    combinator: .and,
                    predicate: MenuBarConditionalPredicate(
                        metric: .sessionResetsIn, comparison: .lessThan, threshold: 2)),
            ],
            thenToken: .lanePercent(lane: .tertiary),
            elseToken: .hidden)
        let selected = MenuBarLayoutConditional(
            clauses: retained.clauses,
            thenToken: .windowResetAbsolute(window: .weekly),
            elseToken: .resetCountdown)
        return Fixture(
            layout: MenuBarLayout(lines: [[
                .icon, .lanePercent(lane: .tertiary), .conditional(id: retained.id),
                .windowResetCountdown(window: .weekly),
            ]]),
            overrides: [
                "codex": MenuBarLayout(lines: [[.icon, .windowResetAbsolute(window: .session)]]),
                "claude": MenuBarLayout(lines: [[.lanePercent(lane: .tertiary), .conditional(id: retained.id)]]),
            ],
            library: [retained, selected],
            retained: retained)
    }

    private func save(_ fixture: Fixture, into defaults: UserDefaults) throws {
        let layout = try MenuBarLayoutPersistence.encoded(fixture.layout)
        let overrides = try MenuBarLayoutPersistence.encodedOverrides(fixture.overrides)
        let library = try MenuBarLayoutPersistence.encodedLibrary(fixture.library)
        for (key, value) in [
            (MenuBarLayoutUserDefaultsKey.layoutCurrent, layout.current),
            ("menuBarLayoutV2", layout.released),
            ("menuBarLayout", layout.legacy),
            (MenuBarLayoutUserDefaultsKey.overridesCurrent, overrides.current),
            ("menuBarLayoutOverridesV2", overrides.released),
            ("menuBarLayoutOverrides", overrides.legacy),
            (MenuBarLayoutUserDefaultsKey.conditionalsCurrent, library.current),
            ("menuBarLayoutConditionalsV2", library.released),
            ("menuBarLayoutConditionals", library.legacy),
        ] {
            defaults.set(value, forKey: key)
        }
        MenuBarLayoutPersistence.stampProjectionVersion(
            forKey: MenuBarLayoutUserDefaultsKey.projectionVersionLayout, in: defaults)
        MenuBarLayoutPersistence.stampProjectionVersion(
            forKey: MenuBarLayoutUserDefaultsKey.projectionVersionOverrides, in: defaults)
        MenuBarLayoutPersistence.stampProjectionVersion(
            forKey: MenuBarLayoutUserDefaultsKey.projectionVersionLibrary, in: defaults)
    }

    private func reload(_ defaults: UserDefaults) -> ReleasedResetV2.State {
        ReleasedResetV2.State(
            layout: MenuBarLayoutPersistence.loadLayout(
                current: self.decode(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent)),
                released: self.decode(defaults.data(forKey: "menuBarLayoutV2")),
                legacy: self.decode(defaults.data(forKey: "menuBarLayout")),
                into: defaults),
            overrides: MenuBarLayoutPersistence.loadOverrides(
                current: self.decode(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)),
                released: self.decode(defaults.data(forKey: "menuBarLayoutOverridesV2")),
                legacy: self.decode(defaults.data(forKey: "menuBarLayoutOverrides")),
                into: defaults),
            library: MenuBarLayoutPersistence.loadLibrary(
                current: self.decode(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.conditionalsCurrent)),
                released: self.decode(defaults.data(forKey: "menuBarLayoutConditionalsV2")),
                legacy: self.decode(defaults.data(forKey: "menuBarLayoutConditionals")),
                into: defaults) ?? [])
    }

    private func decode<T: Decodable>(_ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private struct Fixture {
        let layout: MenuBarLayout
        let overrides: [String: MenuBarLayout]
        let library: [MenuBarLayoutConditional]
        let retained: MenuBarLayoutConditional
    }
}

/// Frozen v0.56.8 decoder and startup behavior. New token discriminators fail the whole layout or
/// override dictionary; conditional libraries instead discard an unreadable entry. Startup rewrites
/// an absent/undecodable V2 layer from V1 even when the user has not opened the editor.
private enum ReleasedResetV2 {
    struct State {
        var layout: MenuBarLayout?
        var overrides: [String: MenuBarLayout]
        var library: [MenuBarLayoutConditional]
    }

    static func startup(_ defaults: UserDefaults) throws -> State {
        let currentLayout = self.layout(defaults.data(forKey: "menuBarLayoutV2"))
        let legacyLayout = self.layout(defaults.data(forKey: "menuBarLayout"))
        let selectedLayout = currentLayout.flatMap { value in
            legacyLayout.map { value.legacyCompatible() == $0 ? value : $0 } ?? value
        } ?? legacyLayout
        if (currentLayout == nil) != (legacyLayout == nil), let selectedLayout {
            try self.writeLayout(selectedLayout, into: defaults)
        }
        let currentOverrides = self.overrides(defaults.data(forKey: "menuBarLayoutOverridesV2"))
        let legacyOverrides = self.overrides(defaults.data(forKey: "menuBarLayoutOverrides"))
        var selectedOverrides = currentOverrides ?? legacyOverrides ?? [:]
        if let currentOverrides, let legacyOverrides,
           currentOverrides.mapValues({ $0.legacyCompatible() }) != legacyOverrides
        {
            selectedOverrides = legacyOverrides
        }
        if (currentOverrides == nil) != (legacyOverrides == nil), !selectedOverrides.isEmpty {
            try self.writeOverrides(selectedOverrides, into: defaults)
        }
        let currentLibrary = self.library(defaults.data(forKey: "menuBarLayoutConditionalsV2"))
        let legacyLibrary = self.library(defaults.data(forKey: "menuBarLayoutConditionals"))
        var selectedLibrary = currentLibrary ?? legacyLibrary ?? []
        if let currentLibrary, let legacyLibrary,
           currentLibrary.compactMap(\.legacyCompatible) != legacyLibrary
        {
            selectedLibrary = legacyLibrary
        }
        if (currentLibrary == nil) != (legacyLibrary == nil) {
            try self.writeLibrary(selectedLibrary, into: defaults)
        }
        return State(layout: selectedLayout, overrides: selectedOverrides, library: selectedLibrary)
    }

    static func save(_ state: State, into defaults: UserDefaults) throws {
        if let layout = state.layout { try self.writeLayout(layout, into: defaults) }
        try self.writeOverrides(state.overrides, into: defaults)
        try self.writeLibrary(state.library, into: defaults)
    }

    private static func writeLayout(_ layout: MenuBarLayout, into defaults: UserDefaults) throws {
        try defaults.set(JSONEncoder().encode(layout), forKey: "menuBarLayoutV2")
        try defaults.set(JSONEncoder().encode(layout.legacyCompatible()), forKey: "menuBarLayout")
    }

    private static func writeOverrides(_ overrides: [String: MenuBarLayout], into defaults: UserDefaults) throws {
        try defaults.set(JSONEncoder().encode(overrides), forKey: "menuBarLayoutOverridesV2")
        try defaults.set(
            JSONEncoder().encode(overrides.mapValues { $0.legacyCompatible() }),
            forKey: "menuBarLayoutOverrides")
    }

    private static func writeLibrary(_ library: [MenuBarLayoutConditional], into defaults: UserDefaults) throws {
        try defaults.set(JSONEncoder().encode(library), forKey: "menuBarLayoutConditionalsV2")
        try defaults.set(
            JSONEncoder().encode(library.compactMap(\.legacyCompatible)),
            forKey: "menuBarLayoutConditionals")
    }

    private static func layout(_ data: Data?) -> MenuBarLayout? {
        guard let data, (try? JSONDecoder().decode(Layout.self, from: data)) != nil else { return nil }
        return try? JSONDecoder().decode(MenuBarLayout.self, from: data)
    }

    private static func overrides(_ data: Data?) -> [String: MenuBarLayout]? {
        guard let data, (try? JSONDecoder().decode([String: Layout].self, from: data)) != nil else { return nil }
        return try? JSONDecoder().decode([String: MenuBarLayout].self, from: data)
    }

    private static func library(_ data: Data?) -> [MenuBarLayoutConditional]? {
        guard let data else { return nil }
        return (try? JSONDecoder().decode([LenientRule].self, from: data))?.compactMap(\.value)
    }

    private struct Layout: Decodable {
        let lines: [[Token]]
    }

    private struct Rule: Decodable {
        let thenToken: Token
        let elseToken: Token
    }

    private struct LenientRule: Decodable {
        let value: MenuBarLayoutConditional?
        init(from decoder: Decoder) throws {
            self.value = (try? Rule(from: decoder)) == nil ? nil : try? MenuBarLayoutConditional(from: decoder)
        }
    }

    private enum Token: Decodable {
        case icon, providerName, accountLabel
        case percent(window: PercentWindow)
        case lanePercent(lane: MenuBarLayoutLane)
        case pace(window: PercentWindow)
        case usageBar, resetCountdown, resetAbsolute, runsOut, runsOutCompact
        case balance, costToday, cost30d, separatorDot, space, hidden
        case conditional(id: UUID)
    }
}
