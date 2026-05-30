import Foundation
import Testing
@testable import CodexBar

@Suite("TerminalApp")
struct TerminalAppTests {
    @Test
    @MainActor
    func `default is terminal`() throws {
        let suite = "TerminalAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(store.terminalApp == .terminal)
    }

    @Test
    @MainActor
    func `setting terminal app persists it`() throws {
        let suite = "TerminalAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        store.terminalApp = .iTerm
        #expect(store.terminalApp == .iTerm)
        #expect(defaults.string(forKey: "terminalApp") == "iTerm")
    }

    @Test
    @MainActor
    func `invalid stored value falls back to terminal`() throws {
        let suite = "TerminalAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("nonexistent", forKey: "terminalApp")
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(store.terminalApp == .terminal)
    }

    @Test
    func `only two cases exist`() {
        #expect(TerminalApp.allCases.count == 2)
    }

    @Test
    func `all cases have unique bundle identifiers`() {
        let ids = TerminalApp.allCases.map(\.bundleIdentifier)
        #expect(Set(ids).count == TerminalApp.allCases.count)
    }

    @Test
    func `all cases have non-empty labels`() {
        for app in TerminalApp.allCases {
            #expect(!app.label.isEmpty)
        }
    }

    @Test
    func `round-trip all cases through raw value`() {
        for app in TerminalApp.allCases {
            #expect(TerminalApp(rawValue: app.rawValue) == app)
        }
    }
}
