import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class CodexSwitcherPrivacyNativeProofTests: XCTestCase {
    func test_privateAccountSwitcher() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_SWITCHER_PRIVACY_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SWITCHER_PRIVACY_PROOF_DIR for signed synthetic UI proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              NSHomeDirectory().hasPrefix(output.deletingLastPathComponent().path + "/")
        else { return XCTFail("Use a contained home and credential/session isolation") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Expectations alone change; baseline screenshots must use the original proposal binary.
        let baseline = environment["CODEXBAR_SWITCHER_PRIVACY_PROOF_BASELINE"] == "1"
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar — Synthetic Account Privacy"
        host.isReleasedWhenClosed = false
        defer {
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
        var receipt: [String: Any] = ["baseline": baseline, "syntheticOnly": true]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 410))
            host.contentView = content
            Self.addLabel("Production Codex account switcher · Synthetic accounts only", y: 365, to: content)
            var rows: [[String: Any]] = []
            for (index, configuration) in [(CGFloat(320), true), (CGFloat(150), true), (CGFloat(320), false)]
                .enumerated()
            {
                let (width, hide) = configuration
                let y = CGFloat(262 - index * 104)
                Self.addLabel("Hide Personal Info: \(hide ? "on" : "off") · \(Int(width)) pt", y: y + 62, to: content)
                rows.append(self.addSwitcher(width: width, hide: hide, baseline: baseline, y: y, to: content))
            }
            content.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x", "-o", "-l", String(host.windowNumber),
                output.appendingPathComponent("switcher-\(appearance.rawValue).png").path,
            ]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            receipt[appearance.rawValue] = rows
        }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }

    private func addSwitcher(
        width: CGFloat,
        hide: Bool,
        baseline: Bool,
        y: CGFloat,
        to content: NSView) -> [String: Any]
    {
        let accounts = Self.accounts()
        var selectedIDs: [String] = []
        let view = CodexAccountSwitcherView(
            accounts: accounts,
            selectedAccountID: accounts[0].id,
            width: width,
            hidePersonalInfo: hide,
            onSelect: { selectedIDs.append($0.id) })
        view.setFrameOrigin(NSPoint(x: 28, y: y))
        content.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let titles = view._test_buttonTitles()
        let tips = view._test_buttonToolTips().compactMap(\.self)
        XCTAssertEqual(titles.count, accounts.count)
        XCTAssertEqual(tips.count, accounts.count)
        if hide, baseline {
            XCTAssertEqual(tips[0], tips[2], "Original proposal collides with a generated account label")
            XCTAssertTrue(tips[3].contains("synthetic.member@example.com"))
        } else if hide {
            XCTAssertEqual(Set(titles).count, accounts.count)
            XCTAssertEqual(Set(tips).count, accounts.count)
            XCTAssertFalse((titles + tips).contains { $0.contains("@") })
            XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
            for (index, title) in titles.enumerated() {
                let ordinal = String(format: L("Account %@"), String(index + 1))
                if width >= 320 {
                    XCTAssertTrue(title.hasPrefix(ordinal), "Wide titles must preserve stable account identity")
                }
                XCTAssertTrue(tips[index].hasPrefix(ordinal))
            }
        } else {
            XCTAssertEqual(tips, accounts.map(\.menuDisplayName))
        }
        let buttons = Self.buttons(in: view)
        for account in accounts {
            let button = buttons.first { $0.identifier?.rawValue == account.id }
            XCTAssertNotNil(button)
            button?.performClick(nil)
        }
        XCTAssertEqual(selectedIDs, accounts.map(\.id))
        return ["width": Double(width), "hidden": hide, "titles": titles, "toolTips": tips, "clickedIDs": selectedIDs]
    }

    private static func accounts() -> [CodexVisibleAccount] {
        let firstOrdinal = String(format: L("Account %@"), "1")
        let workspaces = ["Acme", "Acme", "Acme · \(firstOrdinal)", "Team synthetic.member@example.com"]
        return zip(["a", "b", "c", "d"], workspaces).map { id, workspace in
            CodexVisibleAccount(
                id: id,
                email: "synthetic.\(id)@example.com",
                workspaceLabel: workspace,
                workspaceAccountID: nil,
                authFingerprint: nil,
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: false,
                isLive: false,
                canReauthenticate: false,
                canRemove: false)
        }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            if let button = child as? NSButton { return [button] }
            return Self.buttons(in: child)
        }
    }

    private static func addLabel(_ text: String, y: CGFloat, to content: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.frame = NSRect(x: 28, y: y, width: 660, height: 28)
        content.addSubview(label)
    }
}
