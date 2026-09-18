import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class CodexSystemAccountPrivacyProofTests: XCTestCase {
    private var proofMenu: NSMenu?
    private var proofCapture: Process?
    private var didCapture = false

    func test_syntheticSystemAccountMenu() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_SYSTEM_ACCOUNT_PRIVACY_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SYSTEM_ACCOUNT_PRIVACY_PROOF_DIR for signed synthetic menu proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Use a credential-isolated test host") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic System Account Privacy"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let content = try XCTUnwrap(window.contentView)
        let label = NSTextField(labelWithString: "Hide Personal Info: On · Synthetic accounts only")
        label.font = .systemFont(ofSize: 15)
        label.frame = NSRect(x: 30, y: 240, width: 620, height: 30)
        content.addSubview(label)
        let menu = NSMenu(title: "System Account")
        menu.autoenablesItems = false
        let accounts = ["alex", "blair", "casey"].enumerated().map { index, name in
            CodexVisibleAccount(
                id: name,
                email: "\(name)@example.com",
                workspaceLabel: index == 0 ? "Personal" : "Acme",
                storedAccountID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)"),
                selectionSource: .liveSystem,
                isActive: false,
                isLive: index == 0,
                canReauthenticate: false,
                canRemove: false)
        }
        let items = CodexProviderImplementation.systemAccountMenuItems(
            projection: CodexVisibleAccountProjection(
                visibleAccounts: accounts,
                activeVisibleAccountID: nil,
                liveVisibleAccountID: "alex",
                hasUnreadableAddedAccountStore: false),
            hidePersonalInfo: true,
            isInteractionBlocked: false)
        for item in items {
            let child = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            child.isEnabled = item.isEnabled
            child.state = item.isChecked ? .on : .off
            menu.addItem(child)
        }
        defer {
            menu.cancelTracking()
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
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = window.frame
        let rectangle = "\(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY))," +
            "\(Int(frame.width)),\(Int(frame.height))"
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R", rectangle, output.appendingPathComponent("menu.png").path]
        self.proofMenu = menu
        self.proofCapture = capture
        defer {
            self.proofMenu = nil
            self.proofCapture = nil
        }
        let timer = Timer(
            timeInterval: 1, target: self, selector: #selector(self.captureMenu), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 40, y: 215), in: content)
        timer.invalidate()
        XCTAssertTrue(self.didCapture)
        if self.didCapture { XCTAssertEqual(capture.terminationStatus, 0) }
        try JSONSerialization.data(withJSONObject: [
            "syntheticOnly": true,
            "hidePersonalInfo": true,
            "titles": items.map(\.title),
            "checked": items.map(\.isChecked),
            "enabled": items.map(\.isEnabled),
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("state.json"))
    }

    @objc private func captureMenu() {
        defer { self.proofMenu?.cancelTracking() }
        guard let capture = self.proofCapture else { return }
        do {
            try capture.run()
            self.didCapture = true
            capture.waitUntilExit()
        } catch {
            XCTFail("Could not capture synthetic menu: \(error)")
        }
    }
}
