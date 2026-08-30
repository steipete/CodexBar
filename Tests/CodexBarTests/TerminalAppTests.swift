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
    func `installed terminals always include Terminal and detected alternatives`() {
        let iTermURL = URL(fileURLWithPath: "/Applications/iTerm.app")
        let installed = TerminalApp.installed { bundleIdentifier in
            bundleIdentifier == TerminalApp.iTerm.bundleIdentifier ? iTermURL : nil
        }

        #expect(installed == [.terminal, .iTerm])
        #expect(TerminalApp.installed { _ in nil } == [.terminal])

        let ghosttyURL = URL(fileURLWithPath: "/Applications/Ghostty.app")
        let withGhostty = TerminalApp.installed { bundleIdentifier in
            bundleIdentifier == TerminalApp.ghostty.bundleIdentifier ? ghosttyURL : nil
        }

        #expect(withGhostty == [.terminal, .ghostty])
    }

    @Test
    func `installed Warp uses its native launcher`() throws {
        let warp = try #require(TerminalApp(rawValue: "warp"))
        let warpURL = URL(fileURLWithPath: "/Applications/Warp.app")

        #expect(warp.bundleIdentifier == "dev.warp.Warp-Stable")
        #expect(TerminalApp.installed { $0 == warp.bundleIdentifier ? warpURL : nil } == [.terminal, warp])
        #expect(warp.appleScript(command: "claude") == nil)
    }

    @Test
    func `picker options preserve an unavailable persisted selection`() {
        #expect(TerminalApp.pickerOptions(selected: .terminal) { _ in nil } == [.terminal])
        #expect(TerminalApp.pickerOptions(selected: .iTerm) { _ in nil } == [.terminal, .iTerm])
        #expect(TerminalApp.pickerOptions(selected: .ghostty) { _ in nil } == [.terminal, .ghostty])
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
    func `builds escaped Warp tab config`() {
        let config = TerminalApp.warpTabConfig(
            name: "codexbar-test",
            command: "echo \"hi\" && printf 'a\\b\nc\td\r'",
            directory: #"/tmp/dir "quote"\slash"#)

        #expect(config == #"""
        name = "codexbar-test"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = "/tmp/dir \"quote\"\\slash"
        commands = ["echo \"hi\" && printf 'a\\b\nc\td\r'"]
        """#)
    }

    @Test
    @MainActor
    func `running Warp receives a native tab config`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalAppTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let appURL = URL(fileURLWithPath: "/Applications/Warp.app")
        var launched = false
        var openedURL: URL?

        try await TerminalApp.launchWarp(
            command: "claude",
            homeDirectory: home,
            applicationURL: appURL,
            isRunning: true,
            launchApplication: { _ in launched = true },
            openURL: {
                openedURL = $0
                return true
            },
            sleep: { _ in })

        #expect(launched == false)
        #expect(openedURL?.absoluteString.hasPrefix("warp://tab_config/codexbar-") == true)
        let files = try FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent(".warp/tab_configs"),
            includingPropertiesForKeys: nil)
        let content = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(content.contains(#"commands = ["claude"]"#))
    }

    @Test
    @MainActor
    func `cold Warp launches before routing the tab config`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalAppTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let appURL = URL(fileURLWithPath: "/Applications/Warp.app")
        var events: [String] = []

        try await TerminalApp.launchWarp(
            command: "claude",
            homeDirectory: home,
            applicationURL: appURL,
            isRunning: false,
            launchApplication: { _ in events.append("launch") },
            openURL: { _ in
                events.append("open")
                return true
            },
            sleep: { _ in events.append("sleep") })

        #expect(events == ["launch", "sleep", "open"])
    }

    @Test
    func `builds terminal-specific launch scripts`() throws {
        let command = #"echo "hello""#
        let terminalScript = try #require(TerminalApp.terminal.appleScript(command: command))
        let iTermScript = try #require(TerminalApp.iTerm.appleScript(command: command))
        let ghosttyScript = try #require(TerminalApp.ghostty.appleScript(command: command))

        #expect(terminalScript.contains(#"tell application "Terminal""#))
        #expect(terminalScript.contains(#"do script "echo \"hello\"""#))
        #expect(iTermScript.contains(#"tell application "iTerm""#))
        #expect(iTermScript.contains(#"write text "echo \"hello\"""#))
        #expect(ghosttyScript.contains(#"tell application "Ghostty""#))
        #expect(ghosttyScript.contains(#"new window with configuration {initial input:"echo \"hello\"" & linefeed}"#))
    }
}
