import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutV8PersistenceTests {
    private static let geminiID = "antigravity-quota-summary-gemini-weekly"

    private static let paceLayout = MenuBarLayout(lines: [
        [.icon, .extraPercent(id: Self.geminiID), .separator(.pipe), .extraPace(id: Self.geminiID)],
    ])

    private static let paceLayoutV7 = V7Layout(lines: [
        [.icon, .extraPercent(id: Self.geminiID), .separator(.pipe), .extraPercent(id: Self.geminiID)],
    ])

    @Test
    func `named pace discriminator stays stable and round trips`() throws {
        let token = MenuBarLayoutToken.extraPace(id: Self.geminiID)
        let json = #"{"extraPace":{"id":"\#(Self.geminiID)"}}"#
        #expect(try String(bytes: JSONEncoder().encode(token), encoding: .utf8) == json)
        #expect(try JSONDecoder().decode(MenuBarLayoutToken.self, from: Data(json.utf8)) == token)
    }

    @Test
    func `V7 projection maps named pace to its percentage and a V7 decoder reads it`() throws {
        let decoder = JSONDecoder()
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(Self.paceLayout)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(["antigravity": Self.paceLayout])

        #expect(try decoder.decode(V7Layout.self, from: layoutBlobs.v7) == Self.paceLayoutV7)
        #expect(try decoder.decode([String: V7Layout].self, from: overrideBlobs.v7)["antigravity"]
            == Self.paceLayoutV7)
        #expect(throws: DecodingError.self) {
            try decoder.decode(V7Layout.self, from: layoutBlobs.current)
        }
        for blob in [layoutBlobs.v6, layoutBlobs.v5, layoutBlobs.v4, layoutBlobs.v3, layoutBlobs.released] {
            let layout = try decoder.decode(MenuBarLayout.self, from: blob)
            #expect(!layout.lines.joined().contains(.extraPace(id: Self.geminiID)))
        }
    }

    @Test
    func `a rule using named pace stays visible as the percentage in the V7 library`() throws {
        let decoder = JSONDecoder()
        let rule = Self.rule(thenToken: .extraPace(id: Self.geminiID))
        let blobs = try MenuBarLayoutPersistence.encodedLibrary([rule])

        #expect(throws: DecodingError.self) {
            try decoder.decode([V7Rule].self, from: blobs.current)
        }
        let rules = try decoder.decode([V7Rule].self, from: blobs.v7)
        #expect(rules.map(\.id) == [rule.id])
        #expect(rules.first?.thenToken == .extraPercent(id: Self.geminiID))
    }

    @Test
    func `downgrade without an edit keeps named pace and an unrelated V7 edit keeps it too`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "named-pace-v8", userDefaults: defaults)
        let paceRule = Self.rule(thenToken: .extraPace(id: Self.geminiID))
        let other = Self.rule(thenToken: .resetCountdown)
        settings.setMenuBarLayout(Self.paceLayout, for: nil)
        settings.setMenuBarLayout(Self.paceLayout, for: .antigravity)
        settings.menuBarLayoutConditionals = [paceRule, other]

        let unedited = testSettingsStore(suiteName: "named-pace-v8-return", userDefaults: defaults)
        #expect(unedited.menuBarLayout == Self.paceLayout)
        #expect(unedited.menuBarLayoutOverrides[.antigravity] == Self.paceLayout)
        #expect(unedited.menuBarLayoutConditionals == [paceRule, other])

        let decoder = JSONDecoder()
        let edited = MenuBarLayout(lines: [[.usageBar]])
        var editedOther = other
        editedOther.thenToken = .usageBar
        try self.saveV7(
            layout: edited,
            overrides: decoder.decode(
                [String: MenuBarLayout].self,
                from: #require(defaults.data(forKey: "menuBarLayoutOverridesV7"))),
            rules: [paceRule.v7Compatible, editedOther],
            defaults: defaults)
        let returned = testSettingsStore(suiteName: "named-pace-v8-edited-return", userDefaults: defaults)
        #expect(returned.menuBarLayout == edited)
        #expect(returned.menuBarLayoutOverrides[.antigravity] == Self.paceLayout)
        #expect(returned.menuBarLayoutConditionals == [paceRule, editedOther])

        try self.saveV7(layout: edited, overrides: [:], rules: [editedOther], defaults: defaults)
        let deleted = testSettingsStore(suiteName: "named-pace-v8-deleted", userDefaults: defaults)
        #expect(deleted.menuBarLayoutOverrides[.antigravity] == nil)
        #expect(deleted.menuBarLayoutConditionals == [editedOther])
    }

    @Test
    func `a store holding only V7 keys loads them and writes the V8 generation on first launch`() throws {
        let defaults = InMemoryUserDefaults()
        let layout = MenuBarLayout(lines: [[.providerName, .separator(.pipe), .percent(window: .session)]])
        let override = MenuBarLayout(lines: [[.icon, .percent(window: .weekly)]])
        let rule = Self.rule(thenToken: .resetCountdown)
        try self.saveV7(layout: layout, overrides: ["claude": override], rules: [rule], defaults: defaults)
        for key in ["menuBarLayoutV8", "menuBarLayoutOverridesV8", "menuBarLayoutConditionalsV8"] {
            #expect(defaults.data(forKey: key) == nil)
        }

        let store = testSettingsStore(suiteName: "named-pace-first-launch", userDefaults: defaults)
        #expect(store.menuBarLayout == layout)
        #expect(store.menuBarLayoutOverrides[.claude] == override)
        #expect(store.menuBarLayoutConditionals == [rule])
        #expect(try JSONDecoder().decode(
            MenuBarLayout.self,
            from: #require(defaults.data(forKey: "menuBarLayoutV8"))) == layout)
    }

    /// What a V7 build writes on save: its current generation under V7, then its older projections.
    private func saveV7(
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
            defaults.set(blobs.v7, forKey: prefix + "V7")
            defaults.set(blobs.v6, forKey: prefix + "V6")
            defaults.set(blobs.v5, forKey: prefix + "V5")
            defaults.set(blobs.v4, forKey: prefix + "V4")
            defaults.set(blobs.v3, forKey: prefix + "V3")
            defaults.set(blobs.released, forKey: prefix + "V2")
            defaults.set(blobs.legacy, forKey: prefix)
        }
    }

    private static func rule(thenToken: MenuBarLayoutToken) -> MenuBarLayoutConditional {
        MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .session, comparison: .greaterThan, threshold: 50))],
            thenToken: thenToken,
            elseToken: .hidden)
    }
}

/// Frozen V7 decoder surface: no `extraPace` case, and a synthesized `Codable` enum throws on an unknown
/// case, which discards the whole persisted blob.
private enum V7Token: Codable, Equatable {
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
    case separator(MenuBarLayoutSeparator)
    case space
    case hidden
    case conditional(id: UUID)

    private enum CodingKeys: String, CodingKey {
        case icon, providerName, accountLabel, percent, lanePercent, extraPercent, pace, usageBar, progressBar
        case resetCountdown, resetAbsolute, windowResetCountdown, windowResetAbsolute
        case runsOut, runsOutCompact, balance, costToday, tokensPerMinute, tokensSparkline
        case costWindow = "cost30d"
        case spendAmount, spendBudget
        case separatorDot, separator, space, hidden, conditional
    }
}

private struct V7Layout: Decodable, Equatable {
    let lines: [[V7Token]]
}

private struct V7Rule: Decodable {
    let id: UUID
    let thenToken: V7Token
    let elseToken: V7Token
}
