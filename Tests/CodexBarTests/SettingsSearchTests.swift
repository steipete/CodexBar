import Testing
@testable import CodexBar

struct SettingsSearchTests {
    private static let panes: [SettingsPane] = [.general, .menuBar, .menu, .hooks, .about]

    private static func filtered(_ query: String) -> [SettingsPane] {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            SettingsSearch.filteredPanes(self.panes, query: query)
        }
    }

    @Test
    func `empty query keeps every pane in order`() {
        #expect(Self.filtered("  ") == Self.panes)
    }

    @Test
    func `pane titles match case insensitively`() {
        #expect(Self.filtered("HOOK") == [.hooks])
    }

    @Test
    func `every query word must match the same pane`() {
        #expect(Self.filtered("menu") == [.menuBar, .menu])
        #expect(Self.filtered("menu bar") == [.menuBar])
        #expect(Self.filtered("menu general").isEmpty)
    }

    @Test
    func `matching ignores diacritics`() {
        #expect(SettingsSearch.matches(words: ["CAFE", "lo"], fields: ["Café login"]))
        #expect(!SettingsSearch.matches(words: ["cafe", "missing"], fields: ["Café login"]))
    }
}
