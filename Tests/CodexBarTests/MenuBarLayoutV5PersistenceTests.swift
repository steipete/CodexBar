import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutV5PersistenceTests {
    @Test
    func `V4 downgrade and reupgrade preserve bars while older edits win`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "progress-generation", userDefaults: defaults)
        let layout = MenuBarLayout(lines: [
            [.icon, .progressBar(window: .session), .extraPercent(id: "cursor-grok-bot")],
            [.progressBar(window: .weekly)],
        ])
        let projected = MenuBarLayout(lines: [
            [.icon, .percent(window: .session), .extraPercent(id: "cursor-grok-bot")],
            [.percent(window: .weekly)],
        ])
        var rule = MenuBarLayoutConditional.makeDefault()
        rule.thenToken = .progressBar(window: .scopedWeekly)
        settings.setMenuBarLayout(layout, for: nil)
        settings.setMenuBarLayout(layout, for: .codex)
        settings.setMenuBarLayout(layout, for: .claude)
        settings.menuBarLayoutConditionals = [rule]
        let decoder = JSONDecoder()
        let full = try #require(defaults.data(forKey: "menuBarLayoutV5"))
        let fullRules = try #require(defaults.data(forKey: "menuBarLayoutConditionalsV5"))
        // A frozen strict decoder rejects any discriminator unknown to the V4 app.
        let v4 = try #require(defaults.data(forKey: "menuBarLayoutV4"))
        let strict = try decoder.decode(V4Layout.self, from: v4)
        #expect(strict.lines == [
            [.icon, .percent(window: .session), .extraPercent(id: "cursor-grok-bot")],
            [.percent(window: .weekly)],
        ])
        let overrides = try decoder.decode([String: V4Layout].self, from: #require(
            defaults.data(forKey: "menuBarLayoutOverridesV4")))
        #expect(overrides["codex"] == strict)
        let strictRules = try decoder.decode([V4Rule].self, from: #require(
            defaults.data(forKey: "menuBarLayoutConditionalsV4")))
        #expect(strictRules.first?.thenToken == .percent(window: .scopedWeekly))

        // V4 startup/editor writes its four generations, leaving the unknown V5 keys untouched.
        var olderRule = rule
        olderRule.thenToken = .percent(window: .scopedWeekly)
        try self.saveV4(
            layout: projected,
            overrides: ["codex": projected, "claude": projected],
            rules: [olderRule],
            defaults: defaults)
        #expect(defaults.data(forKey: "menuBarLayoutV5") == full)
        #expect(defaults.data(forKey: "menuBarLayoutConditionalsV5") == fullRules)
        let returned = testSettingsStore(suiteName: "progress-return", userDefaults: defaults)
        #expect(returned.menuBarLayout == layout)
        #expect(returned.menuBarLayoutOverrides[.codex] == layout)
        #expect(returned.menuBarLayoutConditionals == [rule])

        let edited = MenuBarLayout(lines: [[.usageBar]])
        olderRule.thenToken = .usageBar
        try self.saveV4(
            layout: edited,
            overrides: ["codex": edited, "claude": projected],
            rules: [olderRule],
            defaults: defaults)
        let editedReturn = testSettingsStore(suiteName: "progress-edited-return", userDefaults: defaults)
        #expect(editedReturn.menuBarLayout == edited)
        #expect(editedReturn.menuBarLayoutOverrides[.codex] == edited)
        #expect(editedReturn.menuBarLayoutOverrides[.claude] == layout)
        #expect(editedReturn.menuBarLayoutConditionals == [olderRule])
    }

    @Test
    func `historical separator projections do not discard existing window resets on upgrade`() throws {
        let defaults = InMemoryUserDefaults()
        let layout = MenuBarLayout(lines: [[.icon, .separatorDot, .windowResetCountdown(window: .session)]])
        let historical = MenuBarLayout(lines: [[.icon, .separatorDot]])
        for (key, value) in [
            ("menuBarLayoutV4", layout),
            ("menuBarLayoutV3", layout),
            ("menuBarLayoutV2", historical),
            ("menuBarLayout", historical),
        ] {
            try defaults.set(JSONEncoder().encode(value), forKey: key)
        }
        let returned = testSettingsStore(suiteName: "historical-separators", userDefaults: defaults)
        #expect(returned.menuBarLayout == layout)
    }

    private func saveV4(
        layout: MenuBarLayout,
        overrides: [String: MenuBarLayout],
        rules: [MenuBarLayoutConditional],
        defaults: UserDefaults) throws
    {
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(layout)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(overrides)
        let ruleBlobs = try MenuBarLayoutPersistence.encodedLibrary(rules)
        for (prefix, blobs) in [
            ("menuBarLayout", layoutBlobs),
            ("menuBarLayoutOverrides", overrideBlobs),
            ("menuBarLayoutConditionals", ruleBlobs),
        ] {
            defaults.set(blobs.current, forKey: prefix + "V4")
            defaults.set(blobs.v3, forKey: prefix + "V3")
            defaults.set(blobs.released, forKey: prefix + "V2")
            defaults.set(blobs.legacy, forKey: prefix)
        }
    }
}

private enum V4Token: Codable, Equatable {
    case icon
    case percent(window: PercentWindow)
    case usageBar
    case extraPercent(id: String)
    case hidden
}

private struct V4Layout: Decodable, Equatable {
    let lines: [[V4Token]]
}

private struct V4Rule: Decodable {
    let thenToken: V4Token
    let elseToken: V4Token
}
