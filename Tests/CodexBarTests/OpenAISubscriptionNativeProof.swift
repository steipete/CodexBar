import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

/// Runs only in the signed synthetic proof; never launches the installed app or reads provider credentials.
@MainActor
func captureSubscriptionNativeProof(models: [UsageMenuCardView.Model], directory: String) throws {
    let environment = ProcessInfo.processInfo.environment
    precondition(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
    precondition(environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1")
    precondition(environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1")
    precondition(environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1")
    let application = NSApplication.shared
    precondition(application.delegate == nil)
    let previousPolicy = application.activationPolicy()
    let previousApplication = NSWorkspace.shared.frontmostApplication
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 430, height: 440),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.title = "CodexBar subscription — synthetic fixture"
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
    for (index, model) in models.enumerated() {
        let name = index == 0 ? "before" : "after"
        window.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 16) {
                Text(index == 0 ? "Usage ready; billing pending" : "Billing date attached").font(.headline)
                Text("Synthetic account · no provider requests").font(.caption)
                UsageMenuCardView(model: model, width: 370)
                Spacer()
            }.padding(24))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = [
            "-x",
            "-o",
            "-l",
            String(window.windowNumber),
            URL(fileURLWithPath: directory).appendingPathComponent("subscription-\(name).png").path,
        ]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }
}
