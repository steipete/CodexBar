import AppKit
import CodexBarCore
import Observation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarPaceSignTests {
    @Test
    func `sign defaults to usage ahead persists and refreshes the menu without rewriting layouts`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(!settings.menuBarPaceReservePositive)
        #expect(defaults.object(forKey: "menuBarPaceReservePositive") == nil)
        settings.menuBarLayout = MenuBarLayout(lines: [[.pace(window: .weekly)]])
        settings.setMenuBarLayout(MenuBarLayout(lines: [[.pace(window: .session)]]), for: .claude)
        let layout = settings.menuBarLayout
        let overrides = settings.menuBarLayoutOverrides
        let conditionals = settings.menuBarLayoutConditionals
        for value in [true, false] {
            let changed = LockIsolated(false)
            withObservationTracking {
                _ = settings.menuObservationToken
            } onChange: {
                changed.setValue(true)
            }
            settings.menuBarPaceReservePositive = value
            #expect(changed.value)
            #expect(defaults.object(forKey: "menuBarPaceReservePositive") as? Bool == value)
            let restored = testSettingsStore(suiteName: #function, userDefaults: defaults)
            #expect(restored.menuBarPaceReservePositive == value)
            #expect(restored.menuBarLayout == layout)
            #expect(restored.menuBarLayoutOverrides == overrides)
            #expect(restored.menuBarLayoutConditionals == conditionals)
            #expect(restored.menuBarColorPace)
        }
    }

    @Test(arguments: [false, true], [23.0, -23.0, 0.0, 0.3, -0.3])
    func `saved sign preference formats pace without changing its numeric meaning`(
        reservePositive: Bool,
        delta: Double)
    {
        let (settings, store) = self.fixture(reservePositive: reservePositive)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for minutes in [300, 10080] {
            let window = RateWindow(
                usedPercent: 50 + delta,
                windowMinutes: minutes,
                resetsAt: now.addingTimeInterval(Double(minutes) * 30),
                resetDescription: nil)
            let text = store.menuBarLayoutPaceText(
                provider: .claude, window: window, dataConfidence: .unknown, now: now)
            #expect(text == self.expected(delta: delta, reservePositive: reservePositive))
            #expect(store.menuBarLayoutPaceDelta(
                provider: .claude, window: window, dataConfidence: .unknown, now: now) == delta.rounded())
        }
        #expect(store.menuBarLayoutPaceText(
            provider: .claude, window: nil, dataConfidence: .unknown, now: now) == nil)
        #expect(settings.menuBarColorPace)
    }

    @Test(arguments: [false, true], [23.0, -23.0, 0.0])
    func `live editor preview renders every pace token with the saved sign`(
        reservePositive: Bool,
        delta: Double) throws
    {
        let (settings, store) = self.fixture(reservePositive: reservePositive)
        let now = Date()
        let window = { (minutes: Int) in
            RateWindow(
                usedPercent: 50 + delta,
                windowMinutes: minutes,
                resetsAt: now.addingTimeInterval(Double(minutes) * 30),
                resetDescription: nil)
        }
        let snapshot = UsageSnapshot(primary: window(300), secondary: window(10080), updatedAt: now)
        let preview = MenuBarLayoutPreview(layout: .defaultLayout, provider: .claude, settings: settings, store: store)
        let data = preview.liveData(provider: .claude, snapshot: snapshot)
        for (window, metric): (PercentWindow, MenuBarConditionalMetric) in [
            (.session, .sessionPace), (.weekly, .weeklyPace), (.automatic, .automaticPace),
        ] {
            let conditional = MenuBarLayoutConditional(
                clauses: [MenuBarConditionalClause(
                    combinator: nil,
                    predicate: MenuBarConditionalPredicate(metric: metric, comparison: .greaterThan, threshold: 0))],
                thenToken: .pace(window: window),
                elseToken: .hidden)
            let renderer = MenuBarLayoutRenderer()
            let expectedPace = self.expected(delta: delta, reservePositive: reservePositive)
            let expectedValue = "\u{FFFC}\u{2009}\(expectedPace)"
            let expectedTitle = window == .automatic ? "5h \(expectedValue)" : expectedValue
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[.pace(window: window)]]),
                data: data,
                icon: nil,
                options: self.options())
            #expect(output.attributedTitle.string == expectedTitle)
            let expectedColor: NSColor = delta > 0 ? .systemRed : (delta < 0 ? .systemGreen : .controlTextColor)
            let conditionalOutput = renderer.render(
                layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
                data: data,
                icon: nil,
                options: self.options(conditionals: [conditional]))
            #expect(conditionalOutput.attributedTitle.string
                == (delta > 0 ? expectedTitle : ""))
            for rendered in delta > 0 ? [output, conditionalOutput] : [output] {
                let valueRange = (rendered.attributedTitle.string as NSString).range(of: "\u{FFFC}")
                try #require(valueRange.location != NSNotFound)
                rendered.attributedTitle.enumerateAttribute(.foregroundColor, in: valueRange) { color, _, _ in
                    #expect(color as? NSColor == expectedColor)
                }
                if window == .automatic {
                    #expect(rendered.attributedTitle.attribute(
                        .foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .controlTextColor)
                }
            }
        }
    }

    @Test
    func `sample preview updates cached signs while preserving numeric deltas`() {
        let (settings, store) = self.fixture(reservePositive: false)
        let preview = MenuBarLayoutPreview(layout: .defaultLayout, provider: .claude, settings: settings, store: store)
        let renderer = MenuBarLayoutRenderer()
        for reservePositive in [false, true, false] {
            settings.menuBarPaceReservePositive = reservePositive
            let data = preview.representativeData(provider: .claude)
            #expect(data.sessionPace == (reservePositive ? "+23%" : "-23%"))
            #expect(data.weeklyPace == (reservePositive ? "-5%" : "+5%"))
            #expect(data.automaticPace == data.sessionPace)
            #expect(data.metrics.sessionPaceDelta == -23)
            #expect(data.metrics.weeklyPaceDelta == 5)
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[.pace(window: .session), .separatorDot, .pace(window: .weekly)]]),
                data: data,
                icon: nil,
                options: self.options())
            let sessionLabel = MenuBarLayoutToken.pace(window: .session).editorLabel(provider: .claude)
            let weeklyLabel = MenuBarLayoutToken.pace(window: .weekly).editorLabel(provider: .claude)
            #expect(output.accessibilityLabel == (reservePositive
                    ? "\(sessionLabel) +23%, \(weeklyLabel) -5%"
                    : "\(sessionLabel) -23%, \(weeklyLabel) +5%"))
        }
    }

    @Test(arguments: [false, true])
    func `unavailable pace stays neutral in every preview token`(reservePositive: Bool) {
        let (settings, store) = self.fixture(reservePositive: reservePositive)
        let preview = MenuBarLayoutPreview(layout: .defaultLayout, provider: .claude, settings: settings, store: store)
        let data = preview.liveData(
            provider: .claude, snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()))
        for window: PercentWindow in [.session, .weekly, .automatic] {
            let output = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[.pace(window: window)]]),
                data: data,
                icon: nil,
                options: self.options())
            #expect(output.attributedTitle.string == "–")
            #expect(output.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == .controlTextColor)
        }
    }

    @Test(arguments: [false, true])
    func `legacy pace displays use the same sign preference`(reservePositive: Bool) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let window = RateWindow(
            usedPercent: 73,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(150 * 60),
            resetDescription: nil)
        let pace = UsagePace.weekly(window: window, now: now)
        #expect(MenuBarDisplayText.displayText(
            mode: .pace,
            percentWindow: window,
            pace: pace,
            paceReservePositive: reservePositive,
            showUsed: true) == (reservePositive ? "-23%" : "+23%"))
        #expect(MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: window,
            pace: pace,
            paceReservePositive: reservePositive,
            showUsed: true) == (reservePositive ? "73% · -23%" : "73% · +23%"))
    }

    private func options(conditionals: [MenuBarLayoutConditional] = []) -> MenuBarLayoutRenderOptions {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: false,
            showUsed: true,
            conditionals: conditionals,
            appearanceName: "aqua",
            isDebugApp: false,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            colorPace: true)
    }

    private func expected(delta: Double, reservePositive: Bool) -> String {
        switch delta {
        case 23: reservePositive ? "-23%" : "+23%"
        case -23: reservePositive ? "+23%" : "-23%"
        default: "0%"
        }
    }

    private func fixture(reservePositive: Bool) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(
            suiteName: "pace-sign",
            userDefaults: InMemoryUserDefaults(values: ["menuBarPaceReservePositive": reservePositive]),
            config: testConfigWithAllProvidersDisabled())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        return (settings, UsageStore(
            fetcher: UsageFetcher(), browserDetection: BrowserDetection(cacheTTL: 0), settings: settings))
    }
}
