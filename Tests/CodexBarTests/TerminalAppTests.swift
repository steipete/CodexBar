import AppKit
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
    func `installed terminals always include Terminal and detected alternatives`() {
        let iTermURL = URL(fileURLWithPath: "/Applications/iTerm.app")
        let installed = TerminalApp.installed { bundleIdentifier in
            bundleIdentifier == TerminalApp.iTerm.bundleIdentifier ? iTermURL : nil
        }

        #expect(installed == [.terminal, .iTerm])
        #expect(TerminalApp.installed { _ in nil } == [.terminal])
    }

    @Test
    func `picker options preserve an unavailable persisted selection`() {
        #expect(TerminalApp.pickerOptions(selected: .terminal) { _ in nil } == [.terminal])
        #expect(TerminalApp.pickerOptions(selected: .iTerm) { _ in nil } == [.terminal, .iTerm])
    }

    @Test
    @MainActor
    func `picker icon has compact intrinsic size`() {
        let source = NSImage(size: NSSize(width: 128, height: 64))

        let icon = TerminalApp.pickerIcon(from: source)

        #expect(icon.size == NSSize(width: 16, height: 16))
    }

    @Test
    @MainActor
    func `zero size picker icon remains compact`() {
        let icon = TerminalApp.pickerIcon(from: NSImage(size: .zero))

        #expect(icon.size == NSSize(width: 16, height: 16))
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

    @Test
    func `escapes commands embedded in AppleScript strings`() {
        let escaped = TerminalApp.escapeForAppleScript(#"echo "C:\tmp""#)

        #expect(escaped == #"echo \"C:\\tmp\""#)
    }

    @Test
    func `builds terminal-specific launch scripts`() {
        let command = #"echo "hello""#
        let terminalScript = TerminalApp.terminal.appleScript(command: command)
        let iTermScript = TerminalApp.iTerm.appleScript(command: command)

        #expect(terminalScript.contains(#"tell application "Terminal""#))
        #expect(terminalScript.contains(#"do script "echo \"hello\"""#))
        #expect(iTermScript.contains(#"tell application "iTerm""#))
        #expect(iTermScript.contains(#"write text "echo \"hello\"""#))
    }
}
