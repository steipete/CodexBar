import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutV6PersistenceTests {
    @Test
    func `window label preference persists and refreshes menus without changing layout projections`() async {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "window-labels", userDefaults: defaults)
        #expect(settings.menuBarLayoutShowWindowLabels)
        #expect(defaults.object(forKey: "menuBarLayoutShowWindowLabels") == nil)
        settings.setMenuBarLayout(Self.spendLayout, for: nil)
        settings.setMenuBarLayout(Self.spendLayout, for: .claude)
        settings.menuBarLayoutConditionals = [.makeDefault()]
        let keys = [
            "menuBarLayoutV7", "menuBarLayoutV6", "menuBarLayoutV5",
            "menuBarLayoutOverridesV7", "menuBarLayoutOverridesV6", "menuBarLayoutOverridesV5",
            "menuBarLayoutConditionalsV7", "menuBarLayoutConditionalsV6", "menuBarLayoutConditionalsV5",
        ]
        let before = keys.map { defaults.data(forKey: $0) }
        #expect(before.allSatisfy { $0 != nil })
        await confirmation { changed in
            withObservationTracking {
                _ = settings.menuObservationToken
            } onChange: {
                changed()
            }
            settings.menuBarLayoutShowWindowLabels = false
        }
        #expect(keys.map { defaults.data(forKey: $0) } == before)
        let reloaded = testSettingsStore(suiteName: "window-labels-reloaded", userDefaults: defaults)
        #expect(!reloaded.menuBarLayoutShowWindowLabels)
        #expect(reloaded.menuBarLayout == Self.spendLayout)
        #expect(reloaded.menuBarLayoutOverrides[.claude] == Self.spendLayout)
        reloaded.menuBarLayoutShowWindowLabels = true
        #expect(testSettingsStore(suiteName: "window-labels-restored", userDefaults: defaults)
            .menuBarLayoutShowWindowLabels)
        #expect(keys.map { defaults.data(forKey: $0) } == before)
    }

    private static let spendLayout = MenuBarLayout(lines: [[
        .icon,
        .percent(window: .spend),
        .pace(window: .spend),
        .windowResetCountdown(window: .spend),
        .spendAmount,
        .spendBudget,
        .progressBar(window: .session),
        .extraPercent(id: "cursor-grok-bot"),
        .windowResetCountdown(window: .weekly),
    ]])

    /// `spendLayout` as 0.75.0 reads it from the V5 keys.
    private static let spendLayoutV5 = V5Layout(lines: [[
        .icon,
        .progressBar(window: .session),
        .extraPercent(id: "cursor-grok-bot"),
        .windowResetCountdown(window: .weekly),
    ]])

    @Test
    func `spend token discriminators stay stable and round trip`() throws {
        let fixtures: [(MenuBarLayoutToken, String)] = [
            (.percent(window: .spend), #"{"percent":{"window":"spend"}}"#),
            (.pace(window: .spend), #"{"pace":{"window":"spend"}}"#),
            (.windowResetCountdown(window: .spend), #"{"windowResetCountdown":{"window":"spend"}}"#),
            (.windowResetAbsolute(window: .spend), #"{"windowResetAbsolute":{"window":"spend"}}"#),
            (.spendAmount, #"{"spendAmount":{}}"#),
            (.spendBudget, #"{"spendBudget":{}}"#),
        ]
        for (token, json) in fixtures {
            #expect(try String(bytes: JSONEncoder().encode(token), encoding: .utf8) == json)
            #expect(try JSONDecoder().decode(MenuBarLayoutToken.self, from: Data(json.utf8)) == token)
        }
    }

    @Test
    func `V5 projection drops spend tokens but keeps bars named extras and reset windows`() throws {
        let decoder = JSONDecoder()
        let overrides = [
            "claude": Self.spendLayout,
            "cursor": MenuBarLayout(lines: [[.spendBudget, .windowResetAbsolute(window: .session)]]),
        ]
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(Self.spendLayout)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(overrides)

        #expect(try decoder.decode(V5Layout.self, from: layoutBlobs.v5) == Self.spendLayoutV5)
        let projected = try decoder.decode([String: V5Layout].self, from: overrideBlobs.v5)
        #expect(projected["claude"] == Self.spendLayoutV5)
        #expect(projected["cursor"] == V5Layout(lines: [[.windowResetAbsolute(window: .session)]]))
        // V4 and older keep their own projections of the V5 copy: bars become percentages.
        #expect(try decoder.decode(MenuBarLayout.self, from: layoutBlobs.v4) == MenuBarLayout(lines: [[
            .icon,
            .percent(window: .session),
            .extraPercent(id: "cursor-grok-bot"),
            .windowResetCountdown(window: .weekly),
        ]]))
        // The frozen decoder is strict: the current blob, with Spend tokens, would lose the whole layout.
        #expect(throws: DecodingError.self) {
            try decoder.decode(V5Layout.self, from: layoutBlobs.current)
        }
    }

    @Test
    func `a spend only layout projects to the default layout and returns intact`() throws {
        let spendOnly = MenuBarLayout(lines: [[.percent(window: .spend), .spendBudget]])
        let decoder = JSONDecoder()
        let blobs = try MenuBarLayoutPersistence.encoded(spendOnly)

        for blob in [blobs.v5, blobs.v4, blobs.v3, blobs.released, blobs.legacy] {
            #expect(try decoder.decode(MenuBarLayout.self, from: blob) == .defaultLayout)
        }
        #expect(try MenuBarLayoutPersistence.preferredLayout(
            current: decoder.decode(MenuBarLayout.self, from: blobs.current),
            v5: decoder.decode(MenuBarLayout.self, from: blobs.v5),
            v4: decoder.decode(MenuBarLayout.self, from: blobs.v4),
            v3: decoder.decode(MenuBarLayout.self, from: blobs.v3),
            released: decoder.decode(MenuBarLayout.self, from: blobs.released),
            legacy: decoder.decode(MenuBarLayout.self, from: blobs.legacy)) == spendOnly)
    }

    @Test
    func `a row left with only spacing after dropped tokens falls back like an empty row`() {
        #expect(MenuBarLayout(lines: [[.percent(window: .spend), .space]]).v5Compatible() == .defaultLayout)
        #expect(MenuBarLayout(lines: [[.spendBudget, .separatorDot]]).v5Compatible() == .defaultLayout)
        #expect(MenuBarLayout(lines: [[.icon, .percent(window: .session)], [.spendBudget, .separatorDot]])
            .v5Compatible() == MenuBarLayout(lines: [[.icon, .percent(window: .session)]]))
        // The older generations share the projection, so their dropped tokens get the same fallback.
        #expect(MenuBarLayout(lines: [[.tokensPerMinute, .space]]).v4Compatible() == .defaultLayout)
        #expect(MenuBarLayout(lines: [[.extraPercent(id: "cursor-grok-bot"), .separatorDot]]).v3Compatible()
            == .defaultLayout)
        // A row that was only spacing to begin with is the user's choice and stays.
        let spacer = MenuBarLayout(lines: [[.icon], [.separatorDot]])
        #expect(spacer.v5Compatible() == spacer)
    }

    @Test
    func `conditionals reading spend metrics are omitted from V5 and older libraries`() throws {
        let readable = Self.rule(metric: .session, thenToken: .resetCountdown)
        let spendRules = [
            Self.rule(metric: .spend, thenToken: .providerName),
            Self.rule(metric: .spendResetsIn, thenToken: .providerName),
            Self.rule(metric: .spendPace, thenToken: .providerName),
            Self.rule(metric: .spendAmount, thenToken: .providerName),
            Self.rule(metric: .session, thenToken: .percent(window: .spend)),
            Self.rule(metric: .session, thenToken: .providerName, elseToken: .spendBudget),
        ]
        for rule in spendRules {
            #expect(!rule.hasV5Representation)
            #expect(rule.v3Compatible == nil)
            #expect(rule.releasedCompatible == nil)
            #expect(rule.legacyCompatible == nil)
        }

        let blobs = try MenuBarLayoutPersistence.encodedLibrary([readable] + spendRules)
        let decoder = JSONDecoder()
        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.current).count == spendRules.count + 1)
        for blob in [blobs.v5, blobs.v4, blobs.v3, blobs.released, blobs.legacy] {
            #expect(try decoder.decode([V5Rule].self, from: blob).map(\.id) == [readable.id])
        }

        // The shipped Spend rule is dropped the same way; every other shipped rule still reaches 0.75.0.
        let shipped = MenuBarLayoutConditional.shippedLibrary()
        let shippedV5 = try decoder.decode([V5Rule].self, from: MenuBarLayoutPersistence.encodedLibrary(shipped).v5)
        #expect(shipped.contains { !$0.hasV5Representation })
        #expect(shippedV5.map(\.id) == shipped.filter(\.hasV5Representation).map(\.id))
    }

    @Test
    func `an older V5 reader keeps its copy and returning restores spend while its edits win`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "spend-v6", userDefaults: defaults)
        let readable = Self.rule(metric: .session, thenToken: .resetCountdown)
        let spendRule = Self.rule(metric: .spend, thenToken: .percent(window: .spend))
        settings.menuBarLayoutConditionals = [readable, spendRule]
        settings.setMenuBarLayout(Self.spendLayout, for: nil)
        settings.setMenuBarLayout(Self.spendLayout, for: .claude)
        settings.setMenuBarLayout(Self.spendLayout, for: .cursor)
        let full = try #require(defaults.data(forKey: "menuBarLayoutV7"))

        // 0.75.0 decodes every V5 key, so its startup finds all its generations and rewrites nothing.
        let decoder = JSONDecoder()
        #expect(try decoder.decode(V5Layout.self, from: #require(defaults.data(forKey: "menuBarLayoutV5")))
            == Self.spendLayoutV5)
        let v5Overrides = try decoder.decode(
            [String: V5Layout].self,
            from: #require(defaults.data(forKey: "menuBarLayoutOverridesV5")))
        #expect(v5Overrides["claude"] == Self.spendLayoutV5)
        let v5Rules = try decoder.decode(
            [V5Rule].self,
            from: #require(defaults.data(forKey: "menuBarLayoutConditionalsV5")))
        #expect(v5Rules.map(\.id) == [readable.id])

        let returned = testSettingsStore(suiteName: "spend-v6-return", userDefaults: defaults)
        #expect(returned.menuBarLayout == Self.spendLayout)
        #expect(returned.menuBarLayoutOverrides[.claude] == Self.spendLayout)
        #expect(returned.menuBarLayoutConditionals == [readable, spendRule])

        // An edit saved by 0.75.0 writes V5 and older, leaving the unknown V7 keys untouched.
        let edited = MenuBarLayout(lines: [[.usageBar]])
        let projected = try decoder.decode(MenuBarLayout.self, from: #require(defaults.data(forKey: "menuBarLayoutV5")))
        var editedRule = readable
        editedRule.thenToken = .usageBar
        try self.saveV5(
            layout: edited,
            overrides: ["claude": edited, "cursor": projected],
            rules: [editedRule],
            defaults: defaults)
        #expect(defaults.data(forKey: "menuBarLayoutV7") == full)
        let editedReturn = testSettingsStore(suiteName: "spend-v6-edited-return", userDefaults: defaults)
        #expect(editedReturn.menuBarLayout == edited)
        #expect(editedReturn.menuBarLayoutOverrides[.claude] == edited)
        #expect(editedReturn.menuBarLayoutOverrides[.cursor] == Self.spendLayout)
        #expect(editedReturn.menuBarLayoutConditionals == [editedRule, spendRule])
    }

    @Test
    func `a V5 library edit wins on return while spend rules survive it`() {
        let readable = Self.rule(metric: .session, thenToken: .windowResetCountdown(window: .weekly))
        let spendRule = Self.rule(metric: .spend, thenToken: .percent(window: .spend))
        let edited = MenuBarLayoutConditional(
            id: readable.id,
            name: "Edited in 0.75.0",
            clauses: readable.clauses,
            thenToken: .windowResetAbsolute(window: .session),
            elseToken: .hidden)

        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: [readable, spendRule],
            v5: [edited],
            v4: [edited],
            v3: [edited],
            released: [],
            legacy: []) == [edited, spendRule])
        // Clearing the library in 0.75.0 deliberately clears the Spend rules too.
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: [readable, spendRule],
            v5: [],
            v4: [],
            v3: [],
            released: [],
            legacy: []) == [])
        // A V5-only install upgrading to V6 has no current library yet.
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: nil,
            v5: [readable],
            v4: [readable],
            v3: [readable],
            released: [],
            legacy: []) == [readable])
    }

    /// What 0.75.0 writes on save: its current generation under V5, then its older projections.
    private func saveV5(
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
            defaults.set(blobs.current, forKey: prefix + "V5")
            defaults.set(blobs.v4, forKey: prefix + "V4")
            defaults.set(blobs.v3, forKey: prefix + "V3")
            defaults.set(blobs.released, forKey: prefix + "V2")
            defaults.set(blobs.legacy, forKey: prefix)
        }
    }

    private static func rule(
        metric: MenuBarConditionalMetric,
        thenToken: MenuBarLayoutToken,
        elseToken: MenuBarLayoutToken = .hidden)
        -> MenuBarLayoutConditional
    {
        MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: metric, comparison: .greaterThan, threshold: 50))],
            thenToken: thenToken,
            elseToken: elseToken)
    }
}

/// Frozen 0.75.0 decoder surface: its windows and conditional metrics have no Spend cases, and a synthesized
/// `Codable` enum throws on an unknown case.
private enum V5Window: String, Codable {
    case session
    case weekly
    case scopedWeekly
    case automatic
}

private enum V5Token: Codable, Equatable {
    case icon
    case providerName
    case percent(window: V5Window)
    case usageBar
    case progressBar(window: V5Window)
    case extraPercent(id: String)
    case resetCountdown
    case windowResetCountdown(window: V5Window)
    case windowResetAbsolute(window: V5Window)
    case hidden
}

private struct V5Layout: Decodable, Equatable {
    let lines: [[V5Token]]
}

private enum V5Metric: String, Decodable {
    case session, weekly, scopedWeekly, automatic, primaryLane, secondaryLane, tertiaryLane
    case sessionResetsIn, weeklyResetsIn, scopedWeeklyResetsIn, automaticResetsIn
    case sessionPace, weeklyPace, automaticPace, runsOutIn, balance, costToday, cost30d
}

private struct V5Rule: Decodable {
    struct Clause: Decodable {
        struct Predicate: Decodable {
            let metric: V5Metric
        }

        let predicate: Predicate
    }

    let id: UUID
    let clauses: [Clause]
    let thenToken: V5Token
    let elseToken: V5Token
}
