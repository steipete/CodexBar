import Foundation
import Testing
@testable import CodexBar

struct MenuBarLayoutV4PersistenceTests {
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
        #expect(try decoder.decode(PreV3MenuBarLayout.self, from: layoutBlobs.v3)
            == PreV3MenuBarLayout(lines: [[.icon, .windowResetCountdown(window: .weekly)]]))
        let projected = try decoder.decode(
            PreV3MenuBarLayout.self,
            from: encoder.encode(layout.v3Compatible()))
        #expect(try decoder.decode(PreV3MenuBarLayout.self, from: layoutBlobs.v3) == projected)
        #expect(try decoder.decode([String: PreV3MenuBarLayout].self, from: overrideBlobs.v3)["cursor"]
            == PreV3MenuBarLayout(lines: [[.windowResetAbsolute(window: .session)]]))
        #expect(throws: DecodingError.self) {
            try decoder.decode(PreV3MenuBarLayout.self, from: layoutBlobs.current)
        }
    }

    @Test
    func `loading without V4 uses V3 instead of destructive V2 fallback`() throws {
        let defaults = try #require(UserDefaults(suiteName: "MenuBarLayoutV4PersistenceTests"))
        defaults.removePersistentDomain(forName: "MenuBarLayoutV4PersistenceTests")
        defer { defaults.removePersistentDomain(forName: "MenuBarLayoutV4PersistenceTests") }

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
}

private enum PreV3MenuBarLayoutToken: Codable, Equatable {
    case icon
    case windowResetCountdown(window: PercentWindow)
    case windowResetAbsolute(window: PercentWindow)
}

private struct PreV3MenuBarLayout: Codable, Equatable {
    let lines: [[PreV3MenuBarLayoutToken]]
}
