import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class CodexReauthenticationNativeProofTests: XCTestCase {
    func test_systemReauthenticationProgress() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_REAUTH_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_REAUTH_PROOF_DIR for signed synthetic UI proof")
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
        let baseline = environment["CODEXBAR_REAUTH_PROOF_BASELINE"] == "1"
        let account = CodexVisibleAccount(
            id: "account@example.com",
            email: "account@example.com",
            workspaceLabel: "Example Workspace",
            storedAccountID: UUID(),
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [account],
            activeVisibleAccountID: account.id,
            liveVisibleAccountID: account.id,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: true,
            isPromotingSystemAccount: false,
            notice: nil)
        XCTAssertEqual(state.reauthenticateTitle(for: account), baseline ? "Re-auth" : "Re-authenticating…")
        XCTAssertFalse(state.canReauthenticate(account))
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Re-authentication"
        window.isReleasedWhenClosed = false
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
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView = NSHostingView(rootView:
                VStack(alignment: .leading, spacing: 16) {
                    Text(baseline ? "Before: System re-auth progress is missing" :
                        "After: System re-auth progress is shown")
                        .font(.title2.bold())
                    Text("Synthetic saved + System account · System sign-in is in progress")
                        .font(.caption)
                    Form {
                        CodexAccountsSectionView(
                            state: state,
                            setActiveVisibleAccount: { _ in XCTFail("Unexpected selection") },
                            reauthenticateAccount: { _ in XCTFail("Unexpected login") },
                            removeAccount: { _ in XCTFail("Unexpected removal") },
                            requestSystemVisibleAccount: { _ in XCTFail("Unexpected promotion") },
                            addAccount: { XCTFail("Unexpected account creation") })
                    }
                    .formStyle(.grouped)
                }.padding(24)
                    .environment(\.locale, Locale(identifier: "en"))
                    .preferredColorScheme(appearance == .aqua ? .light : .dark))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x", "-o", "-l", String(window.windowNumber),
                output.appendingPathComponent("reauth-\(appearance.rawValue).png").path,
            ]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
        try JSONSerialization.data(withJSONObject: [
            "baseline": baseline, "title": state.reauthenticateTitle(for: account),
            "canReauthenticate": state.canReauthenticate(account),
        ], options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }
}
