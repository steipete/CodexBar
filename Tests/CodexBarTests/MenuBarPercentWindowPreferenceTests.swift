import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarPercentWindowPreferenceTests {
    @Test
    func `picker labels name credit pools and respect reversed semantic windows`() {
        #expect(MenuBarPercentWindowPreference.session.label(for: .warp) == L("Credits"))
        #expect(MenuBarPercentWindowPreference.weekly.label(for: .warp) == L("Add-on credits"))
        #expect(MenuBarPercentWindowPreference.session.label(for: .kimi) == L("5-hour usage"))
        #expect(MenuBarPercentWindowPreference.weekly.label(for: .kimi) == L("7-day usage"))
        #expect(MenuBarPercentWindowPreference.automatic.label(for: .warp) == L("menu_bar_layout_token_auto"))
    }

    @Test
    @MainActor
    func `percent choice preserves explicit reset windows and conditional library through V3 reload`() {
        let rule = MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .weekly, comparison: .greaterThan, threshold: 80))],
            thenToken: .windowResetCountdown(window: .session),
            elseToken: .percent(window: .session))
        let layout = MenuBarLayout(lines: [[
            .icon, .percent(window: .automatic), .windowResetCountdown(window: .weekly),
            .windowResetAbsolute(window: .session), .conditional(id: rule.id), .lanePercent(lane: .tertiary),
        ]])
        let other = MenuBarLayout(lines: [[.windowResetAbsolute(window: .weekly)]])
        let defaults = InMemoryUserDefaults()
        let config = testConfigStore(suiteName: "percent-reset-integration-\(UUID().uuidString)")
        let settings = MenuBarPercentWindowNativeProofTests.settings(defaults: defaults, config: config)
        defer { settings.configFileWatcher?.stop() }
        settings.menuBarIconStyle = .iconAndPercent
        settings.menuBarLayoutConditionals = [rule]
        settings.setMenuBarLayout(layout, for: .codex)
        settings.setMenuBarLayout(other, for: .claude)

        MenuBarPercentWindowPreference.persist(.weekly, appliedTo: layout, for: .codex, settings: settings)
        // Mixed layout: semantic percents unify on Weekly, but the independently chosen Monthly
        // lane survives the picker change.
        let expected = MenuBarLayout(lines: [[
            .icon, .percent(window: .weekly), .windowResetCountdown(window: .weekly),
            .windowResetAbsolute(window: .session), .conditional(id: rule.id), .lanePercent(lane: .tertiary),
        ]])
        #expect(settings.menuBarLayoutResolution(for: .codex).layout == expected)
        let reloaded = MenuBarPercentWindowNativeProofTests.settings(defaults: defaults, config: config)
        defer { reloaded.configFileWatcher?.stop() }
        #expect(reloaded.menuBarLayoutResolution(for: .codex).layout == expected)
        #expect(reloaded.menuBarLayoutResolution(for: .claude).layout == other)
        #expect(reloaded.menuBarLayoutConditionals == [rule])
        #expect(reloaded.menuBarIconStyle == .iconAndPercent)
        #expect(defaults.data(forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent) != nil)
        #expect(!MenuBarPercentWindowPreference.isVisible(
            iconStyle: .iconAndPercent,
            layout: MenuBarLayout(lines: [[.conditional(id: rule.id)]]),
            provider: .codex))
    }

    @Test
    func `a uniform layout maps to a single preference`() {
        #expect(MenuBarPercentWindowPreference.current(
            in: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])) == .automatic)
        #expect(MenuBarPercentWindowPreference.current(
            in: MenuBarLayout(lines: [[.icon, .percent(window: .weekly)]])) == .weekly)
        // Repeated percents that agree still map to one option.
        #expect(MenuBarPercentWindowPreference.current(in: MenuBarLayout(lines: [
            [.icon, .percent(window: .session)],
            [.percent(window: .session)],
        ])) == .session)
    }

    @Test
    func `mixed or absent percents have no single preference`() {
        // Session · Weekly is only describable in the layout editor.
        #expect(MenuBarPercentWindowPreference.current(in: MenuBarLayout(lines: [[
            .icon,
            .percent(window: .session),
            .separatorDot,
            .percent(window: .weekly),
        ]])) == nil)

        let iconOnly = MenuBarLayout(lines: [[.icon]])
        #expect(MenuBarPercentWindowPreference.current(in: iconOnly) == nil)
        #expect(MenuBarPercentWindowPreference.hasPercentToken(in: iconOnly) == false)
        #expect(MenuBarPercentWindowPreference.hasPercentToken(
            in: MenuBarLayout(lines: [[.icon, .percent(window: .weekly)]])))
    }

    @Test
    func `applying a preference rewrites the percent and following pace tokens`() {
        let layout = MenuBarLayout(lines: [
            [.icon, .percent(window: .weekly), .separatorDot, .pace(window: .weekly), .runsOut],
            [.percent(window: .weekly), .costToday],
        ])

        let session = MenuBarPercentWindowPreference.session.applied(to: layout)

        #expect(session.lines == [
            [.icon, .percent(window: .session), .separatorDot, .pace(window: .session), .runsOut],
            [.percent(window: .session), .costToday],
        ])
        #expect(MenuBarPercentWindowPreference.current(in: session) == .session)
    }

    @Test
    func `picker preserves independent pace and monthly percent on mixed layouts`() {
        // Reviewer example: Session % + Weekly pace + independently chosen Monthly %.
        // Selecting Weekly unifies the semantic percents but must not consume the customs.
        let layout = MenuBarLayout(lines: [[
            .icon,
            .percent(window: .session),
            .separatorDot,
            .pace(window: .weekly),
            .separatorDot,
            .lanePercent(lane: .tertiary),
        ]])

        let weekly = MenuBarPercentWindowPreference.weekly.applied(to: layout)

        #expect(weekly.lines == [[
            .icon,
            .percent(window: .weekly),
            .separatorDot,
            .pace(window: .weekly),
            .separatorDot,
            .lanePercent(lane: .tertiary),
        ]])
    }

    @Test
    func `monthly keeps an independently chosen pace`() {
        let layout = MenuBarLayout(lines: [[
            .icon, .percent(window: .session), .separatorDot, .pace(window: .weekly),
        ]])

        #expect(MenuBarPercentWindowPreference.monthly.applied(to: layout).lines == [[
            .icon, .lanePercent(lane: .tertiary), .separatorDot, .pace(window: .weekly),
        ]])
    }

    @Test
    func `current ignores independent direct lanes`() {
        #expect(MenuBarPercentWindowPreference.current(in: MenuBarLayout(lines: [[
            .icon, .percent(window: .weekly), .separatorDot, .lanePercent(lane: .primary),
        ]])) == .weekly)
    }

    @Test
    func `released projection maps monthly pace so reload keeps the saved layout`() throws {
        let layout = MenuBarLayout(lines: [[
            .icon, .lanePercent(lane: .tertiary), .separatorDot, .lanePace(lane: .tertiary),
        ]])
        let blobs = try MenuBarLayoutPersistence.encoded(layout)
        let current = try JSONDecoder().decode(MenuBarLayout.self, from: blobs.current)
        let released = try JSONDecoder().decode(MenuBarLayout.self, from: blobs.released)
        let legacy = try JSONDecoder().decode(MenuBarLayout.self, from: blobs.legacy)
        // Both older projections carry the mapped ordinary pace, so they agree with each other
        // and the reload keeps the V3 layout instead of falling back.
        #expect(released.lines == [[
            .icon, .lanePercent(lane: .tertiary), .separatorDot, .pace(window: .automatic),
        ]])
        #expect(MenuBarLayoutPersistence.preferredLayout(
            current: current,
            released: released,
            legacy: legacy) == layout)
    }

    @Test
    func `switching between preferences round-trips`() {
        let original = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])

        let weekly = MenuBarPercentWindowPreference.weekly.applied(to: original)
        let backToAutomatic = MenuBarPercentWindowPreference.automatic.applied(to: weekly)

        #expect(backToAutomatic == original)
    }

    @Test
    func `monthly preference round-trips through the tertiary lane`() {
        let original = MenuBarLayout(lines: [[
            .icon, .percent(window: .automatic), .separatorDot, .pace(window: .automatic),
        ]])

        let monthly = MenuBarPercentWindowPreference.monthly.applied(to: original)

        #expect(monthly == MenuBarLayout(lines: [[
            .icon, .lanePercent(lane: .tertiary), .separatorDot, .lanePace(lane: .tertiary),
        ]]))
        #expect(MenuBarPercentWindowPreference.current(in: monthly) == .monthly)
        #expect(MenuBarPercentWindowPreference.hasPercentToken(in: monthly))
        #expect(MenuBarPercentWindowPreference.available(for: .opencodego).contains(.monthly))
        #expect(MenuBarPercentWindowPreference.monthly.label(for: .opencodego) == L("Monthly"))
    }

    @Test
    func `leaving monthly rewrites the lane token back to a percent`() {
        let monthly = MenuBarLayout(lines: [[
            .icon, .lanePercent(lane: .tertiary), .separatorDot, .lanePace(lane: .tertiary),
        ]])

        let backToWeekly = MenuBarPercentWindowPreference.weekly.applied(to: monthly)

        #expect(backToWeekly == MenuBarLayout(lines: [[
            .icon, .percent(window: .weekly), .separatorDot, .pace(window: .weekly),
        ]]))
        #expect(MenuBarPercentWindowPreference.current(in: backToWeekly) == .weekly)
        #expect(MenuBarPercentWindowPreference.monthly.applied(to: backToWeekly) == monthly)
    }

    @Test
    func `picker stays hidden unless the global style is icon and percent`() {
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        let options = MenuBarPercentWindowPreference.allCases

        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .iconAndPercent,
            layout: layout,
            available: options))
        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .critters,
            layout: layout,
            available: options) == false)
        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .bars,
            layout: layout,
            available: options) == false)
        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .iconAndPercent,
            layout: MenuBarLayout(lines: [[.icon]]),
            available: options) == false)
    }

    @Test
    func `picker hides when session and weekly cannot apply`() {
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        let automaticOnly = MenuBarPercentWindowPreference.available(
            metrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .monthlyPlan]))

        #expect(automaticOnly == [.automatic])
        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .iconAndPercent,
            layout: layout,
            available: automaticOnly) == false)
        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .iconAndPercent,
            layout: layout,
            available: [.automatic, .session]))
    }

    @Test
    func `available options follow provider percent-window capabilities`() {
        let mistralLike = ProviderMenuBarMetricCapabilities(supported: [.automatic, .monthlyPlan])
        #expect(MenuBarPercentWindowPreference.available(metrics: mistralLike) == [.automatic])

        let sessionOnlyPrimary = ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary])
        #expect(MenuBarPercentWindowPreference.available(metrics: sessionOnlyPrimary) == [.automatic, .session])

        let weeklyPrimary = ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary])
        #expect(MenuBarPercentWindowPreference.available(
            metrics: weeklyPrimary,
            primarySemanticWindow: .weekly) == [.automatic, .weekly])

        #expect(MenuBarPercentWindowPreference.available(
            metrics: .standard) == [.automatic, .session, .weekly])
        #expect(MenuBarPercentWindowPreference.available(for: .mistral) == [.automatic])
        #expect(MenuBarPercentWindowPreference.available(for: .openrouter) == [.automatic, .session])
        #expect(MenuBarPercentWindowPreference.available(for: .codex) == [.automatic, .session, .weekly])
        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .iconAndPercent,
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            provider: .mistral) == false)
    }

    @Test
    @MainActor
    func `persisting a provider window does not flip the global icon style`() {
        let settings = testSettingsStore(
            suiteName: "MenuBarPercentWindowPreferenceTests-preserve-style")
        settings.menuBarIconStyle = .critters
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        settings.setMenuBarLayout(layout, for: .claude)

        MenuBarPercentWindowPreference.persist(
            .session,
            appliedTo: layout,
            for: .claude,
            settings: settings)

        #expect(settings.menuBarIconStyle == .critters)
        #expect(MenuBarPercentWindowPreference.current(in: settings.menuBarLayout(for: .claude)) == .session)
        #expect(settings.menuBarLayoutOverrides[.claude] == MenuBarLayout(lines: [[
            .icon,
            .percent(window: .session),
        ]]))
    }
}
