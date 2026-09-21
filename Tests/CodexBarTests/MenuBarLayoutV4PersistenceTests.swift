import Foundation
import Testing
@testable import CodexBar

struct MenuBarLayoutV4PersistenceTests {
    @Test
    func `unchanged downgrade retains the full layout overrides and library`() throws {
        let layout = MenuBarLayout(lines: [[
            .icon, .extraPercent(id: "cursor-grok-bot"), .windowResetCountdown(window: .weekly),
        ]])
        let layouts = try MenuBarLayoutPersistence.encoded(layout)
        let overrides = try MenuBarLayoutPersistence.encodedOverrides(["cursor": layout])
        var reset = MenuBarLayoutConditional.makeDefault()
        reset.thenToken = .windowResetCountdown(window: .weekly)
        var extra = MenuBarLayoutConditional.makeDefault()
        extra.thenToken = .extraPercent(id: "cursor-grok-bot")
        let library = try MenuBarLayoutPersistence.encodedLibrary([reset, extra])
        let decoder = JSONDecoder()
        #expect(try MenuBarLayoutPersistence.preferredLayout(
            current: decoder.decode(MenuBarLayout.self, from: layouts.current),
            v3: decoder.decode(MenuBarLayout.self, from: layouts.v3),
            released: decoder.decode(MenuBarLayout.self, from: layouts.released),
            legacy: decoder.decode(MenuBarLayout.self, from: layouts.legacy)) == layout)
        #expect(try MenuBarLayoutPersistence.preferredOverrides(
            current: decoder.decode([String: MenuBarLayout].self, from: overrides.current),
            v3: decoder.decode([String: MenuBarLayout].self, from: overrides.v3),
            released: decoder.decode([String: MenuBarLayout].self, from: overrides.released),
            legacy: decoder.decode([String: MenuBarLayout].self, from: overrides.legacy)) == ["cursor": layout])
        #expect(try MenuBarLayoutPersistence.preferredLibrary(
            current: decoder.decode([MenuBarLayoutConditional].self, from: library.current),
            v3: decoder.decode([MenuBarLayoutConditional].self, from: library.v3),
            released: decoder.decode([MenuBarLayoutConditional].self, from: library.released),
            legacy: decoder.decode([MenuBarLayoutConditional].self, from: library.legacy)) == [reset, extra])
        #expect(try decoder.decode([ReleasedV3Conditional].self, from: library.v3).map(\.thenToken)
            == [.windowResetCountdown(window: .weekly)])
    }

    @Test
    func `V3 projection preserves reset selections while V4 keeps named extras`() throws {
        let layout = MenuBarLayout(lines: [[
            .icon,
            .windowResetCountdown(window: .weekly),
            .extraPercent(id: "cursor-grok-bot"),
        ]])
        let overrides = ["cursor": MenuBarLayout(lines: [[
            .windowResetAbsolute(window: .session),
            .extraPercent(id: "cursor-grok-bot"),
        ]])]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(layout)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(overrides)

        #expect(try decoder.decode(MenuBarLayout.self, from: layoutBlobs.current) == layout)
        #expect(try decoder.decode(ReleasedV3MenuBarLayout.self, from: layoutBlobs.v3)
            == ReleasedV3MenuBarLayout(lines: [[.icon, .windowResetCountdown(window: .weekly)]]))
        let projected = try decoder.decode(
            ReleasedV3MenuBarLayout.self,
            from: encoder.encode(layout.v3Compatible()))
        #expect(try decoder.decode(ReleasedV3MenuBarLayout.self, from: layoutBlobs.v3) == projected)
        #expect(try decoder.decode([String: ReleasedV3MenuBarLayout].self, from: overrideBlobs.v3)["cursor"]
            == ReleasedV3MenuBarLayout(lines: [[.windowResetAbsolute(window: .session)]]))
        #expect(throws: DecodingError.self) {
            try decoder.decode(ReleasedV3MenuBarLayout.self, from: layoutBlobs.current)
        }
    }

    @Test
    func `loading without V4 uses V3 instead of destructive V2 fallback`() {
        let defaults = InMemoryUserDefaults()

        let expected = MenuBarLayout(lines: [[.icon, .windowResetCountdown(window: .weekly)]])
        let loaded = MenuBarLayoutPersistence.loadLayout(
            current: nil,
            v3: expected,
            released: expected.releasedCompatible(),
            legacy: expected.legacyCompatible(),
            into: defaults)

        #expect(loaded == expected)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent) != nil)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.layoutV3) != nil)
    }

    @Test
    func `V3 edits win on return upgrade across layouts overrides and conditionals`() {
        let fullLayout = MenuBarLayout(lines: [[
            .icon,
            .windowResetCountdown(window: .weekly),
            .extraPercent(id: "cursor-grok-bot"),
        ]])
        let olderLayoutEdit = MenuBarLayout(lines: [[.icon, .windowResetCountdown(window: .session)]])
        #expect(MenuBarLayoutPersistence.preferredLayout(
            current: fullLayout,
            v3: olderLayoutEdit,
            released: olderLayoutEdit.releasedCompatible(),
            legacy: olderLayoutEdit.legacyCompatible()) == olderLayoutEdit)

        let fullOverrides = ["cursor": fullLayout, "claude": fullLayout]
        let olderOverrideEdit = ["cursor": olderLayoutEdit]
        #expect(MenuBarLayoutPersistence.preferredOverrides(
            current: fullOverrides,
            v3: olderOverrideEdit,
            released: olderOverrideEdit.mapValues { $0.releasedCompatible() },
            legacy: olderOverrideEdit.mapValues { $0.legacyCompatible() }) == olderOverrideEdit)

        let readable = MenuBarLayoutConditional(
            name: "Read reset",
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .session, comparison: .greaterThan, threshold: 50))],
            thenToken: .windowResetCountdown(window: .weekly),
            elseToken: .hidden)
        let namedExtra = MenuBarLayoutConditional(
            name: "Read Grok Bot",
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .session, comparison: .greaterThan, threshold: 50))],
            thenToken: .extraPercent(id: "cursor-grok-bot"),
            elseToken: .hidden)
        let olderConditionalEdit = MenuBarLayoutConditional(
            id: readable.id,
            name: "Edited in V3",
            clauses: readable.clauses,
            thenToken: .windowResetAbsolute(window: .session),
            elseToken: .hidden)
        let returned = MenuBarLayoutPersistence.preferredLibrary(
            current: [readable, namedExtra],
            v3: [olderConditionalEdit],
            released: [],
            legacy: [])
        #expect(returned == [olderConditionalEdit, namedExtra])

        // A V3 user clearing the library deliberately clears V4-only entries too.
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: [readable, namedExtra],
            v3: [],
            released: [],
            legacy: []) == [])
    }
}

private enum ReleasedV3MenuBarLayoutToken: Codable, Equatable {
    case icon
    case hidden
    case windowResetCountdown(window: PercentWindow)
    case windowResetAbsolute(window: PercentWindow)
}

private struct ReleasedV3Conditional: Decodable {
    let thenToken: ReleasedV3MenuBarLayoutToken
    let elseToken: ReleasedV3MenuBarLayoutToken
}

private struct ReleasedV3MenuBarLayout: Codable, Equatable {
    let lines: [[ReleasedV3MenuBarLayoutToken]]
}
