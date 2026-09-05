import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Signed, opt-in native rendering of the production card with synthetic account-paired data.
@MainActor
final class CodexExtraUsageNativeProofTests: XCTestCase {
    func test_dashboardBalanceFreshnessInNativeCards() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXBAR_CREDITS_NATIVE_PROOF"] == "1" else {
            throw XCTSkip("Set CODEXBAR_CREDITS_NATIVE_PROOF=1 to run the native card proof.")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires credential, Keychain, and session isolation.") }

        let fixture = CodexExtraUsageFreshnessTests()
        let old = CreditsSnapshot(remaining: 50, events: [], updatedAt: fixture.now.addingTimeInterval(-60))
        let zero = CodexExtraUsageCost.attaching(
            to: fixture.usage(), credits: fixture.dashboard(balance: 0, date: fixture.now).toCreditsSnapshot())
        let unread = CodexExtraUsageCost.attaching(
            to: fixture.usage(), credits: fixture.dashboard(balance: nil, date: fixture.now).toCreditsSnapshot())
        let purchasedZero = CodexExtraUsageCost.attaching(
            to: fixture.usage(), credits: CreditsSnapshot(remaining: 0, events: [], updatedAt: fixture.now))
        let models = try [
            fixture.card(snapshot: zero, live: old),
            fixture.card(snapshot: unread, live: old),
            fixture.card(snapshot: purchasedZero, live: old),
        ]
        let titles = ["Confirmed zero balance", "Balance unread", "Purchased credits depleted"]
        let application = NSApplication.shared
        guard application.delegate == nil else { return XCTFail("Requires a standalone test application.") }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "CodexBar extra usage — synthetic fixtures"
        window.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 20) {
                Text("Extra usage after a newer dashboard refresh").font(.title2.bold())
                Text("Synthetic account data · older purchased balance: 50 · no provider requests").font(.caption)
                HStack(alignment: .top, spacing: 20) {
                    ForEach(models.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(titles[index]).font(.headline)
                            UsageMenuCardView(model: models[index], width: 330)
                        }
                    }
                }
                Spacer()
            }.padding(24))
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        if let path = environment["CODEXBAR_CREDITS_PROOF_IMAGE"] {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
        XCTAssertNil(models[0].providerCost?.balanceLine)
        XCTAssertEqual(models[1].providerCost?.balanceLine, "Balance: 50")
        XCTAssertNil(models[2].providerCost)
        XCTAssertEqual(models[0].providerCost?.spendLine, "Monthly credit limit: 300 / 400")
    }
}
