import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Signed synthetic proof that claude-swap account segments select details without activating.
///
/// Renders the production `ClaudeSwapAccountSwitcherView` with fictional accounts and captures it,
/// so the reviewed behavior is observable without any real account, credential, or `cswap` run.
/// Follows `CodexSwitcherPrivacyNativeProofTests`.
@MainActor
final class ClaudeSwapViewOnlyNativeProofTests: XCTestCase {
    func test_viewOnlyAccountSelection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_CLAUDE_SWAP_VIEW_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDE_SWAP_VIEW_PROOF_DIR for signed synthetic UI proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        // Same credential/session isolation requirements as CodexSwitcherPrivacyNativeProofTests.
        //
        // That test additionally requires NSHomeDirectory() to sit inside the output's parent.
        // NSHomeDirectory() reads the passwd database rather than $HOME, so that check only holds
        // under a sandbox or container that rewrites the user record; it is deliberately NOT
        // claimed here. Instead the output must live outside the real home, so a run cannot write
        // artifacts into user space. This case needs no credentials at all: every account below is
        // constructed inline, and nothing reads config, the Keychain, or runs cswap.
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              !output.path.hasPrefix(NSHomeDirectory() + "/")
        else { return XCTFail("Use credential/session isolation and an output path outside the home directory") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar — Synthetic claude-swap View-Only Selection"
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

        var receipt: [String: Any] = ["syntheticOnly": true, "activationsStarted": 0]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 340))
            host.contentView = content
            Self.addLabel(
                "Production claude-swap switcher · synthetic accounts · ● marks the active account",
                y: 296,
                to: content)

            var rows: [[String: Any]] = []
            // Slot 2 is the account claude-swap reports active; each row views a different slot,
            // so the capture shows the viewed highlight moving while ● stays put.
            for (index, viewed) in ["2", "7", "9"].enumerated() {
                let y = CGFloat(230 - index * 96)
                let note = switch viewed {
                case "2": "Viewing the active account"
                case "7": "Viewing a healthy inactive account — no activation"
                default: "Viewing an unavailable account — inspectable, not activatable"
                }
                Self.addLabel("\(note) · hidePersonalInfo on", y: y + 30, to: content)
                rows.append(self.addSwitcher(viewedSlot: viewed, y: y, to: content))
            }
            content.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x", "-o", "-l", String(host.windowNumber),
                output.appendingPathComponent("claude-swap-view-only-\(appearance.rawValue).png").path,
            ]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            receipt[appearance.rawValue] = rows
        }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }

    private func addSwitcher(viewedSlot: String, y: CGFloat, to content: NSView) -> [String: Any] {
        let accounts = Self.accounts()
        let display = ClaudeSwapAccountMenuDisplay(
            accounts: accounts,
            layout: .segmented,
            switchingAccountID: nil,
            errorAccountID: nil,
            viewedAccountID: ProviderAccountIdentity(source: "claude-swap", opaqueID: viewedSlot))
        var selected: [String] = []
        let view = ClaudeSwapAccountSwitcherView(
            display: display,
            hidePersonalInfo: true,
            width: 320,
            onSelect: { selected.append($0.opaqueID) })
        view.setFrameOrigin(NSPoint(x: 28, y: y))
        content.addSubview(view)
        view.layoutSubtreeIfNeeded()

        let titles = view._test_titles
        let tips = view._test_toolTips
        XCTAssertEqual(titles.count, accounts.count)
        XCTAssertEqual(tips.count, accounts.count)

        // Privacy: slot ordinals only, never the display email.
        XCTAssertFalse((titles + tips).contains { $0.contains("@") })
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })

        // The ● marker tracks claude-swap's active slot, independent of what is being viewed.
        let marker = ClaudeSwapAccountSwitcherView.activeMarker
        XCTAssertEqual(titles.filter { $0.hasPrefix(marker) }.count, 1)
        XCTAssertTrue(titles.first { $0.hasPrefix(marker) }?.contains("2") == true)

        // The filled highlight tracks the viewed slot, which may differ from the active one.
        XCTAssertEqual(view._test_selectedTitles.count, 1)
        XCTAssertTrue(view._test_selectedTitles[0].contains(viewedSlot))

        // Record the highlight before exercising clicks: `performClick` toggles each button's
        // state, so reading it afterwards would contradict the captured image.
        let highlighted = view._test_selectedTitles

        // Exercise clicks on a separate instance so the captured window keeps its real state.
        // Every segment reports a selection and starts no activation: the view has no path to
        // `switchClaudeSwapAccount`, and `onSelect` is the only thing it can call.
        var clicked: [String] = []
        let clickProbe = ClaudeSwapAccountSwitcherView(
            display: display,
            hidePersonalInfo: true,
            width: 320,
            onSelect: { clicked.append($0.opaqueID) })
        clickProbe.layoutSubtreeIfNeeded()
        for button in clickProbe._test_buttons() {
            button.performClick(nil)
        }
        XCTAssertEqual(clicked, accounts.map(\.id.opaqueID))
        XCTAssertTrue(selected.isEmpty, "The captured view must not be mutated by the click probe")

        return [
            "viewedSlot": viewedSlot,
            "titles": titles,
            "toolTips": tips,
            "highlighted": highlighted,
            "clickedSlots": clicked,
        ]
    }

    /// Slot 2 active, slot 7 healthy inactive, slot 9 unavailable (expired credentials).
    private static func accounts() -> [ProviderAccountUsageSnapshot] {
        [("2", true, true), ("7", false, true), ("9", false, false)].map { slot, isActive, canActivate in
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: "claude-swap", opaqueID: slot),
                provider: .claude,
                displayLabel: "synthetic.\(slot)@example.com",
                isActive: isActive,
                canActivate: !isActive && canActivate,
                snapshot: nil,
                error: nil,
                sourceLabel: "claude-swap")
        }
    }

    private static func addLabel(_ text: String, y: CGFloat, to content: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.frame = NSRect(x: 28, y: y, width: 660, height: 28)
        content.addSubview(label)
    }
}
