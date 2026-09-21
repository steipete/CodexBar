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
    func `setting Warp persists and reloads it`() throws {
        let suite = "TerminalAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = testSettingsStore(suiteName: suite, userDefaults: defaults)
        store.terminalApp = .warp

        let reloaded = testSettingsStore(suiteName: suite, userDefaults: defaults)

        #expect(defaults.string(forKey: "terminalApp") == "warp")
        #expect(reloaded.terminalApp == .warp)
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
    func `Warp is a stable terminal choice`() {
        #expect(TerminalApp.allCases.count == 4)
        #expect(TerminalApp.warp.rawValue == "warp")
        #expect(TerminalApp.warp.label == "Warp")
        #expect(TerminalApp.warp.bundleIdentifier == "dev.warp.Warp-Stable")
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

        let warpURL = URL(fileURLWithPath: "/Applications/Warp.app")
        let withWarp = TerminalApp.installed { bundleIdentifier in
            bundleIdentifier == TerminalApp.warp.bundleIdentifier ? warpURL : nil
        }

        #expect(withWarp == [.terminal, .warp])
    }

    @Test
    func `picker options preserve an unavailable persisted selection`() {
        #expect(TerminalApp.pickerOptions(selected: .terminal) { _ in nil } == [.terminal])
        #expect(TerminalApp.pickerOptions(selected: .iTerm) { _ in nil } == [.terminal, .iTerm])
        #expect(TerminalApp.pickerOptions(selected: .ghostty) { _ in nil } == [.terminal, .ghostty])
        #expect(TerminalApp.pickerOptions(selected: .warp) { _ in nil } == [.terminal, .warp])
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
        #expect(TerminalApp.warp.appleScript(command: command) == nil)
    }

    @Test
    func `escapes every TOML basic string control character`() {
        let value = "a\u{8}\t\n\u{c}\r\"\\\u{1}\u{7f}é"

        #expect(TerminalApp.escapeForTOML(value) == #"a\b\t\n\f\r\"\\\u0001\u007Fé"#)
    }

    @Test
    func `builds a Warp tab config for one terminal pane`() {
        let config = TerminalApp.warpTabConfig(
            name: "codexbar_test",
            command: "printf \"hello\"\nnext",
            directory: #"/tmp/dir "quoted"\child"#)

        #expect(config == WarpTerminalConfig.marker + #"""
        name = "codexbar_test"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = "/tmp/dir \"quoted\"\\child"
        commands = ["printf \"hello\"\nnext"]
        """#)
    }

    @Test
    @MainActor
    func `Warp launch targets the installed app with a private unique config`() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let warpURL = URL(fileURLWithPath: "/Applications/Warp.app")
        let identifier = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let configURL = home
            .appendingPathComponent(".warp/tab_configs")
            .appendingPathComponent("codexbar_00000000000000000000000000000001.toml")
        var openedURLs: [URL] = []
        var openedApplicationURL: URL?
        var openConfiguration: NSWorkspace.OpenConfiguration?
        var cleanupDelay: Duration?
        var cleanupAction: (@MainActor () -> Void)?
        var scripts: [String] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: home,
            applicationURL: { $0 == TerminalApp.warp.bundleIdentifier ? warpURL : nil },
            identifier: { identifier },
            executeAppleScript: {
                scripts.append($0)
                return true
            },
            open: { urls, applicationURL, configuration in
                #expect(FileManager.default.fileExists(atPath: configURL.path))
                openedURLs = urls
                openedApplicationURL = applicationURL
                openConfiguration = configuration
            },
            scheduleCleanup: {
                cleanupDelay = $0
                cleanupAction = $1
            })

        let result = await TerminalLauncher(dependencies: dependencies).launch(
            .warp,
            command: #"echo "hello""#)

        #expect(result == .selected)
        #expect(scripts.isEmpty)
        #expect(openedApplicationURL == warpURL)
        #expect(openedURLs.map(\.absoluteString) == [
            "warp://tab_config/codexbar_00000000000000000000000000000001",
        ])
        #expect(openConfiguration?.activates == true)
        #expect(openConfiguration?.createsNewApplicationInstance == false)
        #expect(openConfiguration?.allowsRunningApplicationSubstitution == false)
        #expect(openConfiguration?.addsToRecentItems == false)

        #expect(cleanupDelay == .seconds(60))
        #expect(cleanupAction != nil)
        #expect(configURL == home
            .appendingPathComponent(".warp/tab_configs")
            .appendingPathComponent("codexbar_00000000000000000000000000000001.toml"))
        let content = try String(contentsOf: configURL, encoding: .utf8)
        #expect(content.contains(#"commands = ["echo \"hello\""]"#))
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        #expect(permissions == 0o600)
        cleanupAction?()
        #expect(FileManager.default.fileExists(atPath: configURL.path) == false)
    }

    @Test
    @MainActor
    func `consecutive Warp launches keep independent configs and cleanup`() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let warpURL = URL(fileURLWithPath: "/Applications/Warp.app")
        let identifiers = try UUIDSequence([
            #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
        ])
        var routedURLs: [URL] = []
        var cleanupActions: [@MainActor () -> Void] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: home,
            applicationURL: { _ in warpURL },
            identifier: { identifiers.next() },
            executeAppleScript: { _ in false },
            open: { urls, _, _ in routedURLs.append(contentsOf: urls) },
            scheduleCleanup: { _, action in cleanupActions.append(action) })
        let launcher = TerminalLauncher(dependencies: dependencies)

        #expect(await launcher.launch(.warp, command: "first") == .selected)
        #expect(await launcher.launch(.warp, command: "second") == .selected)

        #expect(Set(routedURLs).count == 2)
        let files = try FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent(".warp/tab_configs"),
            includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(contents.contains { $0.contains(#"commands = ["first"]"#) })
        #expect(contents.contains { $0.contains(#"commands = ["second"]"#) })
        #expect(cleanupActions.count == 2)

        cleanupActions[0]()
        let afterFirstCleanup = try FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent(".warp/tab_configs"),
            includingPropertiesForKeys: nil)
        #expect(afterFirstCleanup.count == 1)
        #expect(try String(contentsOf: afterFirstCleanup[0], encoding: .utf8).contains(#"commands = ["second"]"#))

        cleanupActions[1]()
        let afterSecondCleanup = try FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent(".warp/tab_configs"),
            includingPropertiesForKeys: nil)
        #expect(afterSecondCleanup.isEmpty)
    }

    @Test
    @MainActor
    func `cleanup failure does not change a successful Warp launch`() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var cleanupAction: (@MainActor () -> Void)?
        var routedConfigURL: URL?
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: home,
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Warp.app") },
            identifier: { UUID() },
            executeAppleScript: { _ in false },
            open: { urls, _, _ in
                let stem = try #require(urls.first?.lastPathComponent)
                routedConfigURL = home.appendingPathComponent(".warp/tab_configs/\(stem).toml")
            },
            scheduleCleanup: { _, action in cleanupAction = action })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.warp, command: "claude")
        let configURL = try #require(routedConfigURL)
        try FileManager.default.removeItem(at: configURL)
        cleanupAction?()

        #expect(result == .selected)
        #expect(cleanupAction != nil)
    }

    @Test
    @MainActor
    func `Warp launch failure cleans up and falls back exactly once`() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let warpURL = URL(fileURLWithPath: "/Applications/Warp.app")
        var scripts: [String] = []
        let unrelatedURL = home.appendingPathComponent(".warp/tab_configs/keep.toml")
        try FileManager.default.createDirectory(
            at: unrelatedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "keep".write(to: unrelatedURL, atomically: true, encoding: .utf8)
        var generatedURL: URL?
        var cleanupScheduleCount = 0
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: home,
            applicationURL: { _ in warpURL },
            identifier: { UUID() },
            executeAppleScript: {
                scripts.append($0)
                return true
            },
            open: { _, _, _ in
                let files = try FileManager.default.contentsOfDirectory(
                    at: unrelatedURL.deletingLastPathComponent(),
                    includingPropertiesForKeys: nil)
                generatedURL = files.first { $0.lastPathComponent.hasPrefix("codexbar_") }
                throw TestLaunchError.failed
            },
            scheduleCleanup: { _, _ in cleanupScheduleCount += 1 })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.warp, command: "claude")

        #expect(result == .fallback)
        #expect(scripts.count == 1)
        #expect(scripts[0].contains(#"tell application "Terminal""#))
        #expect(cleanupScheduleCount == 0)
        #expect(generatedURL != nil)
        #expect(FileManager.default.fileExists(atPath: generatedURL?.path ?? "") == false)
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    @Test
    @MainActor
    func `missing Warp falls back without creating a config`() async {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var scripts: [String] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: home,
            applicationURL: { _ in nil },
            identifier: { UUID() },
            executeAppleScript: {
                scripts.append($0)
                return true
            },
            open: { _, _, _ in Issue.record("open should not run") },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.warp, command: "claude")

        #expect(result == .fallback)
        #expect(scripts.count == 1)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".warp").path) == false)
    }

    @Test
    @MainActor
    func `Warp config creation failure prevents routing and falls back`() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "blocks directory creation".write(
            to: home.appendingPathComponent(".warp"),
            atomically: true,
            encoding: .utf8)
        var openCount = 0
        var scripts: [String] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: home,
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Warp.app") },
            identifier: { UUID() },
            executeAppleScript: {
                scripts.append($0)
                return true
            },
            open: { _, _, _ in openCount += 1 },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.warp, command: "claude")

        #expect(result == .fallback)
        #expect(openCount == 0)
        #expect(scripts.count == 1)
    }

    @Test
    @MainActor
    func `Warp temporary creation failure preserves a preexisting directory`() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let identifier = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let directoryURL = home.appendingPathComponent(".warp/tab_configs")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let temporaryURL = directoryURL
            .appendingPathComponent(".codexbar_00000000000000000000000000000001.toml.tmp")
        let unrelatedURL = directoryURL.appendingPathComponent("keep.toml")
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        try "keep".write(to: unrelatedURL, atomically: true, encoding: .utf8)
        var openCount = 0
        var scripts: [String] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: home,
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Warp.app") },
            identifier: { identifier },
            executeAppleScript: {
                scripts.append($0)
                return true
            },
            open: { _, _, _ in openCount += 1 },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.warp, command: "claude")

        #expect(result == .fallback)
        #expect(openCount == 0)
        #expect(scripts.count == 1)
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    @Test
    @MainActor
    func `successful alternate launch does not fall back`() async {
        var scripts: [String] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: Self.temporaryHome(),
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/iTerm.app") },
            identifier: { UUID() },
            executeAppleScript: {
                scripts.append($0)
                return true
            },
            open: { _, _, _ in Issue.record("open should not run") },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.iTerm, command: "claude")

        #expect(result == .selected)
        #expect(scripts.count == 1)
        #expect(scripts[0].contains(#"tell application "iTerm""#))
    }

    @Test
    @MainActor
    func `Terminal failure does not recurse`() async {
        var scriptCount = 0
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: Self.temporaryHome(),
            applicationURL: { _ in nil },
            identifier: { UUID() },
            executeAppleScript: { _ in
                scriptCount += 1
                return false
            },
            open: { _, _, _ in Issue.record("open should not run") },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.terminal, command: "claude")

        #expect(result == .failed)
        #expect(scriptCount == 1)
    }

    @Test
    @MainActor
    func `failed alternate and Terminal each launch exactly once`() async {
        var scripts: [String] = []
        let dependencies = TerminalLauncher.Dependencies(
            homeDirectory: Self.temporaryHome(),
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/iTerm.app") },
            identifier: { UUID() },
            executeAppleScript: {
                scripts.append($0)
                return false
            },
            open: { _, _, _ in Issue.record("open should not run") },
            scheduleCleanup: { _, _ in Issue.record("cleanup should not be scheduled") })

        let result = await TerminalLauncher(dependencies: dependencies).launch(.iTerm, command: "claude")

        #expect(result == .failed)
        #expect(scripts.count == 2)
        #expect(scripts[0].contains(#"tell application "iTerm""#))
        #expect(scripts[1].contains(#"tell application "Terminal""#))
    }

    private static func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalAppTests-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private final class UUIDSequence {
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        self.values.removeFirst()
    }
}

private enum TestLaunchError: Error {
    case failed
}
