import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class CodexSharedCostNativeProofTests: XCTestCase {
    func test_sharedCostPresentation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_SHARED_COST_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SHARED_COST_PROOF_DIR for signed synthetic UI proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              NSHomeDirectory().hasPrefix(output.deletingLastPathComponent().path + "/")
        else { return XCTFail("Use a contained home and credential/session isolation") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = MenuCardCodexAmbientCostTests.makeFixture()
        defer { fixture.store.stopSharedSpendDashboardPublication() }
        let oldRendering = StatusItemController.menuCardRenderingEnabled
        let oldRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = oldRendering
            StatusItemController.setMenuRefreshEnabledForTesting(oldRefresh)
        }
        let controller = StatusItemController(
            store: fixture.store,
            settings: fixture.settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar — Synthetic Shared Cost"
        host.isReleasedWhenClosed = false
        let legacy = environment["CODEXBAR_SHARED_COST_PROOF_LEGACY"] == "1"
        var count = 2
        var style = CostSummaryDisplayStyle.both
        let holder = SharedCostProofMenu()
        let menu = holder.menu
        var observed = Set<String>()
        var historyOpened = false
        var finished = false
        func populate() {
            menu.removeAllItems()
            fixture.settings.costSummaryDisplayStyle = style
            let display = MenuCardCodexAmbientCostTests.display(count: count)
            let context = MenuCardCodexAmbientCostTests.context(display: display)
            if legacy {
                if !controller.addCompactCodexAccountMenuIfPlanned(
                    display: display, to: menu, captureMenu: menu, context: context)
                {
                    controller.addStackedCodexMenuCards(display, to: menu, context: context)
                }
            } else {
                controller.addCodexAccountMenuCards(display, to: menu, captureMenu: menu, context: context)
            }
        }
        func button(_ title: String, index: Int, action: @escaping @MainActor (NSButton) -> Void) {
            let button = SharedCostProofButton(frame: NSRect(
                x: CGFloat(20 + index * 160),
                y: 800,
                width: 145,
                height: 32))
            button.title = title
            button.callback = action
            button.target = button
            button.action = #selector(SharedCostProofButton.activate)
            host.contentView?.addSubview(button)
        }
        button("Open menu", index: 0) { button in
            populate()
            observed.insert("\(count):\(style.rawValue)")
            menu.popUp(positioning: nil, at: .zero, in: button)
        }
        button("Toggle layout", index: 1) { _ in count = count == 2 ? 5 : 2 }
        button("Inline only", index: 2) { _ in style = .inlineSummary }
        button("Submenu only", index: 3) { _ in style = .costSubmenu }
        button("Both", index: 4) { _ in style = .both }
        button("Finish proof", index: 5) { _ in finished = true }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let ids = holder.menu.items.compactMap { $0.representedObject as? String }
                let costMenu = holder.menu.items.first { $0.representedObject as? String == "menuCardCost" }?.submenu
                historyOpened = historyOpened || controller.openMenus.values.contains { $0 === costMenu }
                let receipt: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier, "window": host.windowNumber,
                    "count": count, "style": style.rawValue, "legacy": legacy,
                    "ids": ids, "observed": observed.sorted(), "historyOpened": historyOpened,
                ]
                do {
                    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                        .write(to: output.appendingPathComponent("state.json"), options: .atomic)
                } catch { XCTFail("Could not write proof receipt") }
            }
        }
        defer {
            timer.invalidate()
            menu.cancelTracking()
            host.close()
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
        RunLoop.main.add(timer, forMode: .common)
        let deadline = Date().addingTimeInterval(600)
        while !finished, Date() < deadline {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            { app.sendEvent(event) }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(observed.contains("2:\(CostSummaryDisplayStyle.both.rawValue)"))
        if !legacy {
            XCTAssertTrue(observed.contains("5:\(CostSummaryDisplayStyle.both.rawValue)"))
            XCTAssertTrue(observed.contains("5:\(CostSummaryDisplayStyle.inlineSummary.rawValue)"))
            XCTAssertTrue(observed.contains("5:\(CostSummaryDisplayStyle.costSubmenu.rawValue)"))
            XCTAssertTrue(historyOpened)
        }
    }
}

@MainActor
private final class SharedCostProofButton: NSButton {
    var callback: (@MainActor (NSButton) -> Void)?

    @objc func activate() {
        self.callback?(self)
    }
}

@MainActor
private final class SharedCostProofMenu {
    let menu = NSMenu()
}
