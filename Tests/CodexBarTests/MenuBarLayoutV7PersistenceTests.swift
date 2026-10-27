import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutV7PersistenceTests {
    private static let rawValuesAndGlyphs: [(MenuBarLayoutSeparator, String, String)] = [
        (.pipe, "pipe", "|"),
        (.slash, "slash", "/"),
        (.hyphen, "hyphen", "-"),
        (.bullet, "bullet", "•"),
        (.diamond, "diamond", "◆"),
        (.hollowDiamond, "hollowDiamond", "◇"),
        (.tilde, "tilde", "~"),
        (.doubleBar, "doubleBar", "‖"),
    ]

    private static let allSeparators = MenuBarLayoutSeparator.allCases.map(MenuBarLayoutToken.separator)

    private static let glyphLayout = MenuBarLayout(lines: [
        [.providerName] + Self.allSeparators + [.percent(window: .session)],
    ])

    private static let glyphLayoutV6 = V6Layout(lines: [
        [.providerName] + Array(repeating: .separatorDot, count: Self.allSeparators.count)
            + [.percent(window: .session)],
    ])

    @Test
    func `separator discriminators and glyphs stay stable and round trip`() throws {
        #expect(MenuBarLayoutSeparator.allCases == Self.rawValuesAndGlyphs.map(\.0))
        for (separator, rawValue, glyph) in Self.rawValuesAndGlyphs {
            #expect(separator.rawValue == rawValue)
            #expect(separator.glyph == glyph)
            let token = MenuBarLayoutToken.separator(separator)
            let json = #"{"separator":{"_0":"\#(rawValue)"}}"#
            #expect(try String(bytes: JSONEncoder().encode(token), encoding: .utf8) == json)
            #expect(try JSONDecoder().decode(MenuBarLayoutToken.self, from: Data(json.utf8)) == token)
            #expect(token.isVisibleSeparator)
        }
        #expect(MenuBarLayoutToken.separatorDot.isVisibleSeparator)
        #expect(!MenuBarLayoutToken.space.isVisibleSeparator)
    }

    @Test
    func `V6 projection maps every new glyph to the dot and a V6 decoder reads it`() throws {
        let decoder = JSONDecoder()
        let overrides = ["claude": Self.glyphLayout]
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(Self.glyphLayout)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(overrides)

        #expect(try decoder.decode(V6Layout.self, from: layoutBlobs.v6) == Self.glyphLayoutV6)
        #expect(try decoder.decode([String: V6Layout].self, from: overrideBlobs.v6)["claude"] == Self.glyphLayoutV6)
        // The frozen decoder is strict: the current blob would lose the whole layout in a V6 build.
        #expect(throws: DecodingError.self) {
            try decoder.decode(V6Layout.self, from: layoutBlobs.current)
        }
        // Every older generation derives from the V6 projection, so none carries a new glyph.
        for blob in [layoutBlobs.v5, layoutBlobs.v4, layoutBlobs.v3, layoutBlobs.released, layoutBlobs.legacy] {
            let layout = try decoder.decode(MenuBarLayout.self, from: blob)
            #expect(!layout.lines.joined().contains(where: Self.isNewGlyph))
            #expect(layout.lines.joined().contains(.separatorDot))
        }
    }

    @Test
    func `a rule using a new glyph stays visible as the dot in every older library`() throws {
        let decoder = JSONDecoder()
        let rule = Self.rule(thenToken: .separator(.pipe), elseToken: .separator(.slash))
        let blobs = try MenuBarLayoutPersistence.encodedLibrary([rule])

        #expect(throws: DecodingError.self) {
            try decoder.decode([V6Rule].self, from: blobs.current)
        }
        for blob in [blobs.v6, blobs.v5, blobs.v4, blobs.v3, blobs.released] {
            let rules = try decoder.decode([V6Rule].self, from: blob)
            #expect(rules.map(\.id) == [rule.id])
            #expect(rules.first?.thenToken == .separatorDot)
            #expect(rules.first?.elseToken == .separatorDot)
        }
        let legacy = try decoder.decode([MenuBarLayoutConditional].self, from: blobs.legacy)
        #expect(legacy.allSatisfy { $0.thenToken == .separatorDot && $0.elseToken == .separatorDot })
    }

    @Test
    func `downgrade without an edit keeps the glyph and an older edit takes the old layout`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "separator-v7", userDefaults: defaults)
        let pipeRule = Self.rule(thenToken: .separator(.pipe))
        settings.setMenuBarLayout(Self.glyphLayout, for: nil)
        settings.setMenuBarLayout(Self.glyphLayout, for: .claude)
        settings.menuBarLayoutConditionals = [pipeRule]

        // A V6 build reads the V6 keys and finds nothing it must rewrite.
        let decoder = JSONDecoder()
        #expect(try decoder.decode(V6Layout.self, from: #require(defaults.data(forKey: "menuBarLayoutV6")))
            == Self.glyphLayoutV6)
        let unedited = testSettingsStore(suiteName: "separator-v7-return", userDefaults: defaults)
        #expect(unedited.menuBarLayout == Self.glyphLayout)
        #expect(unedited.menuBarLayoutOverrides[.claude] == Self.glyphLayout)
        #expect(unedited.menuBarLayoutConditionals == [pipeRule])

        // An unrelated V6 edit rewrites the global layout and carries the projected override and rule back.
        let edited = MenuBarLayout(lines: [[.usageBar]])
        let projectedOverrides = try decoder.decode(
            [String: MenuBarLayout].self,
            from: #require(defaults.data(forKey: "menuBarLayoutOverridesV6")))
        try self.saveV6(
            layout: edited,
            overrides: projectedOverrides,
            rules: [pipeRule.v6Compatible],
            defaults: defaults)
        let returned = testSettingsStore(suiteName: "separator-v7-edited-return", userDefaults: defaults)
        #expect(returned.menuBarLayout == edited)
        #expect(returned.menuBarLayoutOverrides[.claude] == Self.glyphLayout)
        #expect(returned.menuBarLayoutConditionals == [pipeRule])
    }

    @Test
    func `a pipe rule survives reload and an unrelated V6 library edit`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "separator-rule", userDefaults: defaults)
        let pipeRule = Self.rule(thenToken: .separator(.pipe))
        let other = Self.rule(thenToken: .resetCountdown)
        settings.menuBarLayoutConditionals = [pipeRule, other]
        #expect(testSettingsStore(suiteName: "separator-rule-reload", userDefaults: defaults)
            .menuBarLayoutConditionals == [pipeRule, other])

        var editedOther = other
        editedOther.thenToken = .usageBar
        try self.saveV6(
            layout: .defaultLayout,
            overrides: [:],
            rules: [pipeRule.v6Compatible, editedOther],
            defaults: defaults)
        #expect(testSettingsStore(suiteName: "separator-rule-edited", userDefaults: defaults)
            .menuBarLayoutConditionals == [pipeRule, editedOther])

        // Deleting the rule in the V6 build deletes it.
        try self.saveV6(layout: .defaultLayout, overrides: [:], rules: [editedOther], defaults: defaults)
        #expect(testSettingsStore(suiteName: "separator-rule-deleted", userDefaults: defaults)
            .menuBarLayoutConditionals == [editedOther])
    }

    @Test
    func `a V6 only install upgrading to V7 keeps its layout and library`() {
        let readable = Self.rule(thenToken: .resetCountdown)
        let layout = MenuBarLayout(lines: [[.providerName, .separatorDot, .percent(window: .session)]])
        #expect(MenuBarLayoutPersistence.preferredLayout(
            current: nil,
            v6: layout,
            v5: layout,
            v4: layout,
            v3: layout,
            released: layout,
            legacy: layout) == layout)
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: nil,
            v6: [readable],
            v5: [readable],
            v4: [readable],
            v3: [readable],
            released: [readable],
            legacy: [readable]) == [readable])
    }

    @Test
    func `a store holding only V6 keys loads them and writes the V7 generation on first launch`() throws {
        let defaults = InMemoryUserDefaults()
        let layout = MenuBarLayout(lines: [[.providerName, .separatorDot, .percent(window: .session)]])
        let override = MenuBarLayout(lines: [[.icon, .percent(window: .weekly)]])
        let rule = Self.rule(thenToken: .resetCountdown)
        try self.saveV6(layout: layout, overrides: ["claude": override], rules: [rule], defaults: defaults)
        for key in ["menuBarLayoutV7", "menuBarLayoutOverridesV7", "menuBarLayoutConditionalsV7"] {
            #expect(defaults.data(forKey: key) == nil)
        }

        let store = testSettingsStore(suiteName: "separator-first-launch", userDefaults: defaults)
        #expect(store.menuBarLayout == layout)
        #expect(store.menuBarLayoutOverrides[.claude] == override)
        #expect(store.menuBarLayoutConditionals == [rule])
        // The first load materializes V7, and the V6 copies stay readable by the V6 build.
        let decoder = JSONDecoder()
        #expect(try decoder.decode(
            MenuBarLayout.self,
            from: #require(defaults.data(forKey: "menuBarLayoutV7"))) == layout)
        #expect(try decoder.decode(V6Layout.self, from: #require(defaults.data(forKey: "menuBarLayoutV6")))
            == V6Layout(lines: [[.providerName, .separatorDot, .percent(window: .session)]]))
        #expect(try decoder.decode(
            [V6Rule].self,
            from: #require(defaults.data(forKey: "menuBarLayoutConditionalsV6"))).map(\.id) == [rule.id])
    }

    /// What a V6 build writes on save: its current generation under V6, then its older projections.
    private func saveV6(
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
            defaults.set(blobs.current, forKey: prefix + "V6")
            defaults.set(blobs.v5, forKey: prefix + "V5")
            defaults.set(blobs.v4, forKey: prefix + "V4")
            defaults.set(blobs.v3, forKey: prefix + "V3")
            defaults.set(blobs.released, forKey: prefix + "V2")
            defaults.set(blobs.legacy, forKey: prefix)
        }
    }

    private static func isNewGlyph(_ token: MenuBarLayoutToken) -> Bool {
        guard case .separator = token else { return false }
        return true
    }

    private static func rule(
        thenToken: MenuBarLayoutToken,
        elseToken: MenuBarLayoutToken = .hidden)
        -> MenuBarLayoutConditional
    {
        MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .session, comparison: .greaterThan, threshold: 50))],
            thenToken: thenToken,
            elseToken: elseToken)
    }
}

/// Frozen V6 decoder surface (v0.77.0 to v0.82.0): no `separator` case, and a synthesized `Codable` enum throws
/// on an unknown case, which discards the whole persisted blob.
private enum V6Token: Codable, Equatable {
    case icon
    case providerName
    case accountLabel
    case percent(window: PercentWindow)
    case lanePercent(lane: MenuBarLayoutLane)
    case extraPercent(id: String)
    case pace(window: PercentWindow)
    case usageBar
    case progressBar(window: PercentWindow)
    case resetCountdown
    case resetAbsolute
    case windowResetCountdown(window: PercentWindow)
    case windowResetAbsolute(window: PercentWindow)
    case runsOut
    case runsOutCompact
    case balance
    case costToday
    case tokensPerMinute
    case tokensSparkline
    case costWindow
    case spendAmount
    case spendBudget
    case separatorDot
    case space
    case hidden
    case conditional(id: UUID)

    private enum CodingKeys: String, CodingKey {
        case icon, providerName, accountLabel, percent, lanePercent, extraPercent, pace, usageBar, progressBar
        case resetCountdown, resetAbsolute, windowResetCountdown, windowResetAbsolute
        case runsOut, runsOutCompact, balance, costToday, tokensPerMinute, tokensSparkline
        case costWindow = "cost30d"
        case spendAmount, spendBudget
        case separatorDot, space, hidden, conditional
    }
}

private struct V6Layout: Decodable, Equatable {
    let lines: [[V6Token]]
}

private struct V6Rule: Decodable {
    let id: UUID
    let thenToken: V6Token
    let elseToken: V6Token
}
