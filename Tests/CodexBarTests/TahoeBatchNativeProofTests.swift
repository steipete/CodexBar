import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class TahoeBatchNativeProofTests: XCTestCase {
    func test_statusItemAndMergedMenu() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_TAHOE_BATCH_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_TAHOE_BATCH_PROOF_DIR for signed synthetic diagnostics")
        }
        guard env["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              env[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              env["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1"
        else { return XCTFail("Use credential isolation") }
        let output = URL(
            fileURLWithPath: path,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true)
        for name in ["done", "state.json", "selection"] {
            let file = output.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let oldPolicy = app.activationPolicy()
        let oldAppearance = app.appearance
        let previous = NSWorkspace.shared.frontmostApplication
        _ = app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        app.finishLaunching()
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        let previousRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousRefresh)
        }
        let controller = fixture.makeController()
        defer {
            controller.releaseStatusItemsForTesting()
            app.appearance = oldAppearance
            _ = app.setActivationPolicy(oldPolicy)
            previous?.activate()
        }
        let menu = try XCTUnwrap(controller.mergedMenu)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 500,
                height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Tahoe Diagnostics"
        window.isReleasedWhenClosed = false
        let button = TahoeBatchMenuButton(frame: NSRect(
            x: 120,
            y: 55,
            width: 260,
            height: 36))
        button.title = "Open three-account menu"
        button.menuToOpen = menu
        button.target = button
        button.action = #selector(TahoeBatchMenuButton.openMenu)
        window.contentView?.addSubview(button)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { menu.cancelTracking(); window.close() }
        let deadline = Date().addingTimeInterval(600)
        let menuState = TahoeBatchMenuState(menu: menu)
        let automatic = env["CODEXBAR_TAHOE_BATCH_AUTORUN"] == "1"
        if automatic {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { button.performClick(nil) }
        }
        let timer = Timer(
            timeInterval: 0.5,
            repeats: true)
        { _ in
            MainActor.assumeIsolated {
                let menu = menuState.menu
                let percent = FileManager.default.fileExists(atPath: output.appendingPathComponent("percent").path)
                let style: MenuBarIconStyle = percent ? .iconAndPercent : .bars
                if fixture.settings.menuBarIconStyle != style {
                    fixture.settings.menuBarIconStyle = style
                    controller.updateIcons()
                }
                let command = (try? String(
                    contentsOf: output.appendingPathComponent("selection"),
                    encoding: .utf8)) ?? ""
                if command != menuState.previousCommand,
                   let index = Int(command.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    _ = (menu.items.first?.view as? ProviderSwitcherView)?.handleKeyboardSelection(at: index)
                    menuState.previousCommand = command
                }
                let menuWindow = menu.items.compactMap { $0.view?.window }.first
                let itemButton = controller.statusItem.button
                let servers = MenuBarStatusItemWindowProbe.snapshots(matching: [controller.statusItem.autosaveName])
                let receipt: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
                    "iconStyle": fixture.settings.menuBarIconStyle.rawValue,
                    "selected": fixture.settings.selectedMenuProvider?.rawValue ?? "none",
                    "overview": fixture.settings.mergedMenuLastSelectedWasOverview,
                    "menuSize": NSStringFromSize(menu.size), "menuWindow": menuWindow?.windowNumber ?? -1,
                    "menuFrame": menuWindow.map { NSStringFromRect($0.frame) } ?? "none",
                    "tables": menuWindow?.contentView.map(Self.tables) ?? [],
                    "visible": controller.statusItem.isVisible, "buttonWindow": itemButton?.window != nil,
                    "buttonFrame": itemButton.flatMap { button in
                        button.window
                            .map { NSStringFromRect($0.convertToScreen(button.convert(button.bounds, to: nil))) }
                    } ?? "none",
                    "buttonCoordinateSystem": "Cocoa screen, bottom-left origin",
                    "buttonWindowFrame": itemButton?.window.map { NSStringFromRect($0.frame) } ?? "none",
                    "template": itemButton?.image?.isTemplate ?? false,
                    "title": itemButton?.attributedTitle.string ?? "",
                    "servers": servers.map(Self.serverReceipt),
                ]
                try? JSONSerialization.data(withJSONObject: receipt).write(
                    to: output.appendingPathComponent("state.json"),
                    options: .atomic)
                if automatic, menuWindow != nil {
                    Self.advanceAutomaticProof(menuState, receipt: receipt, button: button, output: output)
                }
                if Date() > deadline || FileManager.default
                    .fileExists(atPath: output.appendingPathComponent("done").path)
                {
                    menu.cancelTracking()
                }
            }
        }
        RunLoop.main.add(
            timer,
            forMode: .common)
        defer { timer.invalidate() }
        while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path) {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                app.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("state.json").path))
        if automatic {
            XCTAssertEqual(menuState.phase, 4)
        }
    }

    private static func serverReceipt(_ server: MenuBarStatusItemWindowSnapshot) -> [String: Any] {
        [
            "name": server.name, "owner": server.ownerName,
            "bounds": NSStringFromRect(server.bounds),
            "displayBounds": server.displayBounds.map(NSStringFromRect) ?? "none",
            "coordinateSystem": "Quartz screen, top-left origin",
            "onscreen": server.isOnscreen, "withinDisplay": server.isWithinDisplayBounds,
        ]
    }

    private static func advanceAutomaticProof(
        _ state: TahoeBatchMenuState,
        receipt: [String: Any],
        button: NSButton,
        output: URL)
    {
        state.ticks += 1
        guard state.ticks.isMultiple(of: 4), state.phase < 4 else { return }
        try? JSONSerialization.data(withJSONObject: receipt).write(
            to: output.appendingPathComponent("phase-\(state.phase).json"), options: .atomic)
        state.phase += 1
        switch state.phase {
        case 1: _ = (state.menu.items.first?.view as? ProviderSwitcherView)?.handleKeyboardSelection(at: 1)
        case 2: _ = (state.menu.items.first?.view as? ProviderSwitcherView)?.handleKeyboardSelection(at: 2)
        case 3:
            state.menu.cancelTracking()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { button.performClick(nil) }
        default:
            state.menu.cancelTracking()
            try? Data().write(to: output.appendingPathComponent("done"))
        }
    }

    private static func makeFixture() throws -> CodexWorkspacesNavigationFixture {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        fixture.settings.mergeIcons = true
        fixture.settings.menuBarDisplayMode = .percent
        fixture.settings.menuBarIconStyle = .bars
        fixture.settings.menuBarHidesCritters = true
        fixture.settings.menuBarHighContrastOnInactiveDisplays = true
        fixture.settings.setMenuBarLayout(MenuBarLayout(lines: [[.percent(window: .automatic)]]), for: nil)
        fixture.settings.selectedMenuProvider = .claude
        fixture.settings.multiAccountMenuLayout = .stacked
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        for provider in [UsageProvider.codex, .claude, .gemini] {
            fixture.settings.setProviderEnabled(
                provider: provider,
                metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
                enabled: true)
            fixture.store._setSnapshotForTesting(
                snapshot,
                provider: provider)
        }
        for index in 0..<3 {
            fixture.settings.addTokenAccount(
                provider: .claude,
                label: "Synthetic \(index + 1)",
                token: "fixture-\(index)")
        }
        fixture.settings.setActiveTokenAccountIndex(
            0,
            for: .claude)
        fixture.store.accountSnapshots[.claude] = fixture.settings.tokenAccounts(for: .claude).map { account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: snapshot,
                error: nil,
                sourceLabel: "fixture",
                cacheKey: fixture.store.tokenAccountSnapshotCacheKey(
                    provider: .claude,
                    account: account))
        }
        return fixture
    }

    private static func tables(_ view: NSView) -> [String] {
        let own = view is NSTableView ? [NSStringFromRect(view.frame)] : []
        return own + view.subviews.flatMap(self.tables)
    }
}

@MainActor
private final class TahoeBatchMenuButton: NSButton {
    var menuToOpen: NSMenu?
    @objc func openMenu() {
        self.menuToOpen?.popUp(
            positioning: nil,
            at: NSPoint(
                x: 0,
                y: self.bounds.maxY),
            in: self)
    }
}

@MainActor
private final class TahoeBatchMenuState {
    let menu: NSMenu
    var previousCommand = ""
    var phase = 0
    var ticks = 0
    init(menu: NSMenu) {
        self.menu = menu
    }
}
