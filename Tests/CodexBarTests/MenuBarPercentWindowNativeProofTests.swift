import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class MenuBarPercentWindowNativeProofTests: XCTestCase {
    func test_providerPickerPersistence() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_PERCENT_POINTER_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PERCENT_POINTER_DIR for native picker proof")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1"
        else { return XCTFail("Requires an isolated test host") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = InMemoryUserDefaults(values: ["debugDisableKeychainAccess": true])
        let config = CodexBarConfigStore(fileURL: output.appendingPathComponent("config.json"))
        try config.save(CodexBarConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: $0 == .codex || $0 == .claude)
        }))
        let settings = Self.settings(defaults: defaults, config: config)
        defer { settings.configFileWatcher?.stop() }
        settings.menuBarIconStyle = .iconAndPercent
        settings.setMenuBarLayout(MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]), for: nil)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar Synthetic Percent Picker Proof"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Form {
            Text("Codex").font(.headline)
            ProviderMenuBarPercentWindowSettingsView(provider: .codex, settings: settings)
            Text("Claude").font(.headline)
            ProviderMenuBarPercentWindowSettingsView(provider: .claude, settings: settings)
        }.formStyle(.grouped).frame(width: 620, height: 380))
        defer {
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(600)
        let done = output.appendingPathComponent("done").path
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            let receipt = [
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "window": String(window.windowNumber),
                "codex": MenuBarPercentWindowPreference.current(
                    in: settings.menuBarLayoutResolution(for: .codex).layout)?.rawValue ?? "custom",
                "claude": MenuBarPercentWindowPreference.current(
                    in: settings.menuBarLayoutResolution(for: .claude).layout)?.rawValue ?? "custom",
            ]
            try JSONEncoder().encode(receipt).write(to: output.appendingPathComponent("state.json"), options: .atomic)
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                app.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native proof timed out")
        XCTAssertEqual(MenuBarPercentWindowPreference.current(
            in: settings.menuBarLayoutResolution(for: .codex).layout), .weekly)
        XCTAssertEqual(MenuBarPercentWindowPreference.current(
            in: settings.menuBarLayoutResolution(for: .claude).layout), .automatic)
        let reloaded = Self.settings(defaults: defaults, config: config)
        defer { reloaded.configFileWatcher?.stop() }
        XCTAssertEqual(
            reloaded.menuBarLayoutResolution(for: .codex).layout,
            settings.menuBarLayoutResolution(for: .codex).layout)
        XCTAssertEqual(reloaded.menuBarIconStyle, .iconAndPercent)
    }

    static func settings(defaults: UserDefaults, config: CodexBarConfigStore) -> SettingsStore {
        SettingsStore(
            userDefaults: defaults,
            configStore: config,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            performInitialProviderDetection: false)
    }
}
