import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class DevinQuotaVisibilityNativeProofTests: XCTestCase {
    func test_dailyVisibilityInProductionCards() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_DEVIN_VISIBILITY_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_DEVIN_VISIBILITY_PROOF_DIR for signed synthetic UI proof")
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
        let baseline = environment["CODEXBAR_DEVIN_VISIBILITY_PROOF_BASELINE"] == "1"
        let now = Date()
        let models = try [true, false].map { hideDaily in
            let snapshot = try DevinUsageParser.parse(
                [
                    "hide_daily_quota": hideDaily,
                    "daily_percentage": 0,
                    "weekly_percentage": 90,
                    "daily_reset_at": now.addingTimeInterval(86400).timeIntervalSince1970,
                    "weekly_reset_at": now.addingTimeInterval(172_800).timeIntervalSince1970,
                ],
                organization: nil,
                now: now).toUsageSnapshot()
            return try UsageMenuCardView.Model.make(.init(
                provider: .devin,
                metadata: XCTUnwrap(ProviderDefaults.metadata[.devin]),
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                now: now))
        }
        // Baseline expectations use the original parser binary with the same synthetic response.
        XCTAssertEqual(models[0].metrics.map(\.id), baseline ? ["primary", "secondary"] : ["secondary"])
        XCTAssertEqual(models[1].metrics.map(\.id), ["primary", "secondary"])
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Devin Quota Visibility"
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
                VStack(alignment: .leading, spacing: 18) {
                    Text(baseline ? "Before: hidden daily quota still appears" :
                        "After: daily visibility follows Devin")
                        .font(.title2.bold())
                    Text("Synthetic response · Weekly 90% used · Production parser and menu cards")
                        .font(.caption)
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(models.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(index == 0 ? "Daily hidden by provider" : "Daily visible (unchanged)")
                                    .font(.headline)
                                UsageMenuCardView(model: models[index], width: 360)
                            }
                        }
                    }
                    Spacer()
                }.padding(24)
                    .environment(\.locale, Locale(identifier: "en"))
                    .preferredColorScheme(appearance == .aqua ? .light : .dark))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x", "-o", "-l", String(window.windowNumber),
                output.appendingPathComponent("devin-\(appearance.rawValue).png").path,
            ]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
        let receipt: [String: Any] = [
            "baseline": baseline,
            "hiddenDailyMetrics": models[0].metrics.map(\.id),
            "visibleDailyMetrics": models[1].metrics.map(\.id),
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }
}
