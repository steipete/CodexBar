import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreMergeIconStackedTests {
    @Test
    func `stacked projection preserves layout inheritance preferences and restart state`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "Stacked-persistence", userDefaults: defaults)
        settings.mergeIcons = true
        settings.menuBarIconStyle = .iconAndPercent
        settings.mergedIconDisplayStyle = .stacked
        settings.mergeIconStackedTopProvider = .cursor
        settings.mergeIconStackedBottomProvider = .claude
        let shared = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)], [.costToday]])
        let custom = MenuBarLayout(lines: [[.providerName, .resetCountdown], [.cost30d]])
        settings.setMenuBarLayout(shared, for: nil)
        settings.setMenuBarLayout(custom, for: .claude)

        let fallback = settings.mergedIconPresentation(activeProviders: [.codex, .claude])
        #expect(fallback.stackedProviders?.providers == [.codex, .claude])
        #expect(settings.mergeIconStackedTopProvider == .cursor)
        #expect(fallback.renderedResolution(settings.menuBarLayoutResolution(for: .claude), for: .claude)
            .layout.lines == [custom.lines[0]])
        #expect(settings.menuBarLayout(for: .codex) == shared)
        #expect(settings.menuBarLayout(for: .claude) == custom)

        let reloaded = testSettingsStore(suiteName: "Stacked-reload", userDefaults: defaults)
        #expect(reloaded.mergedIconDisplayStyle == .stacked)
        #expect(reloaded.mergedIconPresentation(activeProviders: [.codex, .claude, .cursor])
            .stackedProviders?.providers == [.cursor, .claude])
        #expect(reloaded.menuBarLayout(for: .codex) == shared)
        #expect(reloaded.menuBarLayout(for: .claude) == custom)
        reloaded.mergedIconDisplayStyle = .switcher
        #expect(!reloaded.mergeIconsStacked)
        #expect(reloaded.menuBarLayout(for: .claude) == custom)
    }
}
