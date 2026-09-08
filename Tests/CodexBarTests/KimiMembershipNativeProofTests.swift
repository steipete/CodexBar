import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class KimiMembershipNativeProofTests: XCTestCase {
    func test_membershipInProductionMenuCard() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXBAR_KIMI_NATIVE_PROOF"] == "1" else {
            throw XCTSkip("Set CODEXBAR_KIMI_NATIVE_PROOF=1 for signed synthetic UI proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires credential and session isolation") }
        let directory = try XCTUnwrap(environment["CODEXBAR_KIMI_PROOF_DIRECTORY"])
        let json = """
        {"user":{"membership":{"level":"LEVEL_ADVANCED"}},"version":"GOODS_VERSION_V1",
         "usage":{"limit":"100","used":"25","remaining":"75"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"100","used":"10","remaining":"90"}}]}
        """
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let after = try KimiUsageFetcher._parseCodeAPIUsageForTesting(Data(json.utf8), now: now)
        let before = KimiUsageSnapshot(
            weekly: after.weekly,
            rateLimit: after.rateLimit,
            rateLimitWindow: after.rateLimitWindow,
            subscriptionBalance: nil,
            updatedAt: now)
        let snapshots = [before.toUsageSnapshot(), after.toUsageSnapshot()]
        XCTAssertNil(snapshots[0].loginMethod(for: .kimi))
        XCTAssertEqual(snapshots[1].loginMethod(for: .kimi), "Allegro")
        XCTAssertEqual(snapshots[0].primary, snapshots[1].primary)
        XCTAssertEqual(snapshots[0].secondary, snapshots[1].secondary)
        let application = NSApplication.shared
        guard application.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "CodexBar Kimi membership — synthetic fixture"
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
        for (index, snapshot) in snapshots.enumerated() {
            let model = try UsageMenuCardView.Model.make(.init(
                provider: .kimi,
                metadata: XCTUnwrap(ProviderDefaults.metadata[.kimi]),
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .kimi)),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                now: now))
            window.contentView = NSHostingView(rootView:
                VStack(alignment: .leading, spacing: 16) {
                    Text(index == 0 ? "Before: membership omitted" : "After: membership displayed").font(.headline)
                    Text("Synthetic API data · identical quotas · no provider requests").font(.caption)
                    UsageMenuCardView(model: model, width: 370)
                    Spacer()
                }.padding(24))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            let name = index == 0 ? "before" : "after"
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x",
                "-o",
                "-l",
                String(window.windowNumber),
                URL(fileURLWithPath: directory).appendingPathComponent("kimi-\(name).png").path,
            ]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
    }
}
