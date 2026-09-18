import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in AppKit proof using app-local appearance changes and synthetic provider data.
@MainActor
final class StatusMenuAppearanceNativeProofTests: XCTestCase {
    func test_firstOpeningAfterAppearanceChange() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_APPEARANCE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_APPEARANCE_PROOF_DIR for isolated native proof")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil
        else { return XCTFail("Native proof requires credential and session isolation") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousAppearance = app.appearance
        let previousPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        app.appearance = light
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        let previousRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousRefresh)
        }
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let merged = try XCTUnwrap(controller.mergedMenu)
        let provider = controller.makeMenu(for: .codex)
        controller.providerMenus[UsageProvider.codex.instanceID] = provider
        let fallback = NSMenu()
        let submenu = NSMenu()
        fallback.autoenablesItems = false
        submenu.autoenablesItems = false
        submenu.addItem(withTitle: "Synthetic daily details", action: nil, keyEquivalent: "")
        let history = NSMenuItem(title: "Synthetic cost history", action: nil, keyEquivalent: "")
        history.submenu = submenu
        fallback.addItem(history)
        StatusMenuAppearance.pin(fallback, to: light)
        StatusMenuAppearance.pin(submenu, to: light)
        controller.fallbackMenu = fallback
        let menus = ["merged": merged, "provider": provider, "nested": fallback]
        let proofMenus = AppearanceProofMenus(values: menus, submenu: submenu)
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar Synthetic Appearance Proof"
        host.isReleasedWhenClosed = false
        var desired = "light"
        var opened: [[String: String]] = []
        var changes = 0
        var finished = false
        func addButton(_ title: String, x: CGFloat, y: CGFloat, action: @escaping @MainActor () -> Void) {
            let button = AppearanceProofButton(frame: NSRect(x: x, y: y, width: 180, height: 32))
            button.title = title
            button.onActivate = action
            button.target = button
            button.action = #selector(AppearanceProofButton.activate)
            host.contentView?.addSubview(button)
        }
        addButton("Use Light", x: 30, y: 530) { desired = "light"; changes += 1; app.appearance = light }
        addButton("Use Dark", x: 225, y: 530) { desired = "dark"; changes += 1; app.appearance = dark }
        addButton("Finish proof", x: 420, y: 530) { finished = true }
        for (name, x, y) in [("merged", 30, 430), ("provider", 225, 430), ("nested", 30, 350)] {
            let menu = try XCTUnwrap(menus[name])
            let button = AppearanceProofButton(frame: NSRect(
                x: CGFloat(x),
                y: CGFloat(y),
                width: 180,
                height: 32))
            button.title = "Open \(name) menu"
            button.onActivate = { [weak button] in
                guard let button else { return }
                let actual = menu.effectiveAppearance.bestMatch(from: [
                    .aqua,
                    .darkAqua,
                ]) == .darkAqua ? "dark" : "light"
                opened.append(["menu": name, "desired": desired, "beforeOpen": actual])
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
            }
            button.target = button
            button.action = #selector(AppearanceProofButton.activate)
            host.contentView?.addSubview(button)
        }
        defer {
            for menu in menus.values {
                menu.cancelTracking()
            }
            host.close()
            app.appearance = previousAppearance
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        host.center()
        host.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let state: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "window": host.windowNumber,
                    "desired": desired,
                    "changes": changes,
                    "opened": opened,
                    "appearances": proofMenus.values.mapValues { $0.appearance?.name.rawValue ?? "inherited" },
                    "submenuAppearance": proofMenus.submenu.appearance?.name.rawValue ?? "inherited",
                    "submenuEffective": proofMenus.submenu.effectiveAppearance.name.rawValue,
                    "tracking": controller.openMenus.count,
                    "fallbackStillOwned": controller.fallbackMenu === proofMenus.values["nested"],
                    "providerStillOwned": controller.providerMenus[UsageProvider.codex.instanceID] === proofMenus
                        .values["provider"],
                ]
                do {
                    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(
                        to: directory.appendingPathComponent("state.json"), options: .atomic)
                } catch { XCTFail("Could not write appearance receipt: \(error)") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let deadline = Date().addingTimeInterval(600)
        while !finished, Date() < deadline {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            { app.sendEvent(event) }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(finished, "Native proof timed out")
        XCTAssertGreaterThanOrEqual(changes, 2)
        for name in menus.keys {
            for appearance in ["light", "dark"] {
                XCTAssertTrue(opened.contains { $0["menu"] == name && $0["desired"] == appearance })
            }
        }
        let allMatched = opened.allSatisfy { $0["beforeOpen"] == $0["desired"] }
        XCTAssertEqual(allMatched, environment["CODEXBAR_APPEARANCE_EXPECT_FIXED"] == "1")
    }

    private static func makeFixture() throws -> CodexWorkspacesNavigationFixture {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        fixture.settings.mergeIcons = true
        fixture.settings.selectedMenuProvider = .codex
        fixture.settings.setProviderEnabled(
            provider: .claude,
            metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
            enabled: true)
        for provider in [UsageProvider.codex, .claude] {
            fixture.store._setSnapshotForTesting(UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()), provider: provider)
        }
        return fixture
    }
}

@MainActor
private final class AppearanceProofMenus {
    let values: [String: NSMenu]
    let submenu: NSMenu

    init(values: [String: NSMenu], submenu: NSMenu) {
        self.values = values
        self.submenu = submenu
    }
}

@MainActor
private final class AppearanceProofButton: NSButton {
    var onActivate: (@MainActor () -> Void)?

    @objc func activate() {
        self.onActivate?()
    }
}
