import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MenuBarPercentWindowPreferenceTests {
    @Test
    func `opencode monthly is available in both percentage controls before data arrives`() {
        #expect(MenuBarPercentWindowPreference.available(for: .opencodego)
            .map { $0.label(for: .opencodego) }.contains(L("Monthly")))
        #expect(MenuBarLayoutLane.available(for: .opencodego).contains(.tertiary))
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
        #expect(MenuBarLayoutLane.available(for: .opencodego, snapshot: snapshot).contains(.tertiary))
    }

    @Test
    func `tertiary choices use provider labels without exposing snapshot-required lanes`() {
        #expect(MenuBarPercentWindowPreference.available(for: .opencodego).contains(.tertiary))
        #expect(MenuBarPercentWindowPreference.tertiary.label(for: .opencodego) == L("Monthly"))
        #expect(MenuBarPercentWindowPreference.available(for: .perplexity).contains(.tertiary))
        #expect(MenuBarPercentWindowPreference.tertiary.label(for: .perplexity) == L("Purchased"))
        #expect(!MenuBarPercentWindowPreference.available(for: .cursor).contains(.tertiary))
        #expect(!MenuBarPercentWindowPreference.available(for: .codex).contains(.tertiary))
    }

    @Test(arguments: [PercentWindow.automatic, .weekly])
    func `monthly to weekly round trip preserves independent layout tokens`(_ pace: PercentWindow) {
        let ruleID = UUID()
        let original = MenuBarLayout(lines: [
            [
                .icon,
                .percent(window: .session),
                .separatorDot,
                .pace(window: pace),
                .windowResetCountdown(window: .session),
            ],
            [
                .lanePercent(lane: .primary),
                .percent(window: .session),
                .lanePercent(lane: .secondary),
                .conditional(id: ruleID),
            ],
        ])
        let monthly = MenuBarPercentWindowPreference.tertiary.applied(to: original)
        #expect(monthly.lines == [
            [
                .icon,
                .lanePercent(lane: .tertiary),
                .separatorDot,
                .pace(window: pace),
                .windowResetCountdown(window: .session),
            ],
            [
                .lanePercent(lane: .primary),
                .lanePercent(lane: .tertiary),
                .lanePercent(lane: .secondary),
                .conditional(id: ruleID),
            ],
        ])
        #expect(MenuBarPercentWindowPreference.current(in: monthly) == .tertiary)
        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .iconAndPercent, layout: monthly, provider: .opencodego))
        let weekly = MenuBarPercentWindowPreference.weekly.applied(to: monthly)
        #expect(weekly == MenuBarPercentWindowPreference.weekly.applied(to: original))
        #expect(MenuBarPercentWindowPreference.current(in: weekly) == .weekly)
        #expect(MenuBarPercentWindowPreference.session.applied(to: monthly) == original)
    }

    @Test
    func `mixed ordinary and independent tertiary percentages cannot be collapsed by the picker`() {
        let ruleID = UUID()
        let layout = MenuBarLayout(lines: [[
            .percent(window: .session), .lanePercent(lane: .tertiary), .pace(window: .automatic),
            .windowResetAbsolute(window: .weekly), .conditional(id: ruleID),
        ]])
        #expect(!MenuBarPercentWindowPreference.available(for: .opencodego, layout: layout).contains(.tertiary))
        #expect(MenuBarPercentWindowPreference.tertiary.applied(to: layout) == layout)
        #expect(MenuBarPercentWindowPreference.current(in: layout) == .session)
        let weekly = MenuBarPercentWindowPreference.weekly.applied(to: layout)
        #expect(weekly.lines == [[
            .percent(window: .weekly), .lanePercent(lane: .tertiary), .pace(window: .automatic),
            .windowResetAbsolute(window: .weekly), .conditional(id: ruleID),
        ]])
        #expect(MenuBarPercentWindowPreference.current(in: weekly) == .weekly)
    }

    @Test
    @MainActor
    func `a stale picker binding rechecks and preserves the current custom layout`() {
        let box = PercentLayoutTestBox()
        let picker = ProviderMenuBarPercentWindowPicker(
            provider: .opencodego,
            iconStyle: .iconAndPercent,
            layout: Binding(get: { box.layout }, set: { box.layout = $0 }))
        let selection = picker.selectionBinding
        let edited = MenuBarLayout(lines: [[
            .percent(window: .weekly), .lanePercent(lane: .tertiary), .windowResetAbsolute(window: .session),
        ]])
        box.layout = edited
        #expect(selection.wrappedValue == .weekly)
        selection.wrappedValue = .tertiary
        #expect(box.layout == edited)
        selection.wrappedValue = .session
        #expect(box.layout == MenuBarPercentWindowPreference.session.applied(to: edited))
    }

    @Test
    @MainActor
    func `monthly uses existing layout encodings and respects older release edits`() throws {
        let monthly = MenuBarPercentWindowPreference.tertiary.applied(to: MenuBarLayout(lines: [[
            .percent(window: .session),
        ]]))
        let encoded = try MenuBarLayoutPersistence.encoded(monthly, provider: .opencodego)
        let decoder = JSONDecoder()
        let current = try decoder.decode(MenuBarLayout.self, from: encoded.current)
        let released = try decoder.decode(MenuBarLayout.self, from: encoded.released)
        let legacy = try decoder.decode(MenuBarLayout.self, from: encoded.legacy)
        #expect(current == monthly)
        #expect(released == monthly)
        #expect(legacy == MenuBarLayout(lines: [[.percent(window: .automatic)]]))
        #expect(MenuBarLayoutPersistence.loadLayout(
            current: current, released: released, legacy: legacy, into: InMemoryUserDefaults()) == monthly)
        let olderEdit = MenuBarLayout(lines: [[.percent(window: .weekly)]])
        #expect(MenuBarLayoutPersistence.preferredLayout(
            current: current, released: olderEdit, legacy: olderEdit) == olderEdit)
        let key = UsageProvider.opencodego.rawValue
        let overrides = try MenuBarLayoutPersistence.encodedOverrides([key: monthly])
        let currentOverrides = try decoder.decode([String: MenuBarLayout].self, from: overrides.current)
        let releasedOverrides = try decoder.decode([String: MenuBarLayout].self, from: overrides.released)
        let legacyOverrides = try decoder.decode([String: MenuBarLayout].self, from: overrides.legacy)
        #expect(MenuBarLayoutPersistence.preferredOverrides(
            current: currentOverrides, released: releasedOverrides, legacy: legacyOverrides) == [key: monthly])
        #expect(MenuBarLayoutPersistence.preferredOverrides(
            current: currentOverrides, released: [:], legacy: [:]).isEmpty)
    }

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

        let picker = ProviderMenuBarPercentWindowSettingsView(provider: .codex, settings: settings)
        picker.layoutBinding.wrappedValue = MenuBarPercentWindowPreference.weekly.applied(to: layout)
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
    func `applying a preference rewrites only the percent tokens`() {
        let layout = MenuBarLayout(lines: [
            [.icon, .percent(window: .weekly), .separatorDot, .runsOut],
            [.percent(window: .automatic), .costToday],
        ])

        let session = MenuBarPercentWindowPreference.session.applied(to: layout)

        #expect(session.lines == [
            [.icon, .percent(window: .session), .separatorDot, .runsOut],
            [.percent(window: .session), .costToday],
        ])
        #expect(MenuBarPercentWindowPreference.current(in: session) == .session)
    }

    @Test
    func `switching between preferences round-trips`() {
        let original = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])

        let weekly = MenuBarPercentWindowPreference.weekly.applied(to: original)
        let backToAutomatic = MenuBarPercentWindowPreference.automatic.applied(to: weekly)

        #expect(backToAutomatic == original)
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
        let settings = MenuBarPercentWindowNativeProofTests.settings(
            defaults: InMemoryUserDefaults(),
            config: testConfigStore(suiteName: "MenuBarPercentWindowPreferenceTests-preserve-style"))
        defer { settings.configFileWatcher?.stop() }
        settings.menuBarIconStyle = .critters
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        settings.setMenuBarLayout(layout, for: .claude)

        let picker = ProviderMenuBarPercentWindowSettingsView(provider: .claude, settings: settings)
        picker.layoutBinding.wrappedValue = MenuBarPercentWindowPreference.session.applied(to: layout)

        #expect(settings.menuBarIconStyle == .critters)
        #expect(MenuBarPercentWindowPreference.current(in: settings.menuBarLayout(for: .claude)) == .session)
        #expect(settings.menuBarLayoutOverrides[.claude] == MenuBarLayout(lines: [[
            .icon,
            .percent(window: .session),
        ]]))
    }
}

@MainActor
private final class PercentLayoutTestBox {
    var layout = MenuBarLayout(lines: [[.percent(window: .session)]])
}
