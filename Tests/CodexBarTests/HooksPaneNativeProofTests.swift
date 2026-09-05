import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class HooksPaneNativeProofTests: XCTestCase {
    func test_groupedHookEditorLabels() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXBAR_HOOKS_NATIVE_PROOF"] == "1" else {
            throw XCTSkip("Set CODEXBAR_HOOKS_NATIVE_PROOF=1 for synthetic Hooks UI proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires credential and session isolation") }
        let output = try XCTUnwrap(environment["CODEXBAR_HOOKS_PROOF_PATH"])
        let application = NSApplication.shared
        guard application.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 850),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "CodexBar Hooks — synthetic settings fixture"
        window.contentView = NSHostingView(rootView: HooksProofForm().preferredColorScheme(.dark))
        defer {
            window.close()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        _ = application.setActivationPolicy(.regular)
        application.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
    }
}

/// Production row bindings with no SettingsStore, config persistence, provider, or hook runner.
@MainActor
private struct HooksProofForm: View {
    @State private var rules: [HookRule] = [90, 95, 98].map { percent in
        HookRule(
            id: "fixture-\(percent)",
            enabled: false,
            event: .quotaLow,
            provider: "codex",
            threshold: Double(percent) / 100,
            executable: "/fixture/quota-alert",
            arguments: ["--message", "Quota warning"])
    } + [HookRule(id: "fixture-empty", enabled: false, event: .quotaLow, executable: "", arguments: [""])]

    var body: some View {
        Form {
            Section {
                Text("Synthetic rules only. No commands can run from this fixture.")
                    .font(.caption)
            } header: {
                Text("Hooks settings — populated and empty fields")
            }
            Section {
                ForEach(self.$rules) { $rule in
                    HookRuleRow(rule: $rule, onDelete: {})
                }
            }
        }
        .formStyle(.grouped)
    }
}
