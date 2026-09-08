import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class ClaudeWeeklyLabelsNativeProofTests: XCTestCase {
    func test_weeklyLabelsInProductionMenuCard() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["CODEXBAR_WEEKLY_LABEL_PROOF_DIRECTORY"] else {
            throw XCTSkip("Set CODEXBAR_WEEKLY_LABEL_PROOF_DIRECTORY for signed synthetic UI proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires credential and session isolation") }
        let phase = try XCTUnwrap(environment["CODEXBAR_WEEKLY_LABEL_PROOF_PHASE"])
        XCTAssertTrue(["before", "after"].contains(phase))
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let application = NSApplication.shared
        guard application.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 510),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.title = "CodexBar weekly labels — synthetic fixture"
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
        let now = Date()
        for language in ["en", "zh-Hans", "vi"] {
            try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                let scoped = NamedRateWindow(
                    id: "claude-weekly-scoped-example-model",
                    title: "Example Model only",
                    window: RateWindow(
                        usedPercent: 25,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(5 * 86400),
                        resetDescription: nil))
                let snapshot = UsageSnapshot(
                    primary: nil,
                    secondary: RateWindow(
                        usedPercent: 40,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(5 * 86400),
                        resetDescription: nil),
                    extraRateWindows: [scoped],
                    updatedAt: now)
                let model = try UsageMenuCardView.Model.make(.init(
                    provider: .claude,
                    metadata: XCTUnwrap(ProviderDefaults.metadata[.claude]),
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
                    usageBarsShowUsed: true,
                    resetTimeDisplayStyle: .countdown,
                    tokenCostUsageEnabled: false,
                    showOptionalCreditsAndExtraUsage: true,
                    hidePersonalInfo: true,
                    now: now))
                XCTAssertEqual(snapshot.extraRateWindows?.first?.title, "Example Model only")
                window.contentView = NSHostingView(rootView:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(phase.capitalized) · \(language)").font(.headline)
                        Text("Synthetic quota data · no provider requests").font(.caption)
                        UsageMenuCardView(model: model, width: 370)
                        Spacer()
                    }.padding(24)
                        .environment(\.locale, Locale(identifier: language))
                        .preferredColorScheme(.light))
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = [
                    "-x", "-o", "-l", String(window.windowNumber),
                    output.appendingPathComponent("weekly-\(language)-\(phase).png").path,
                ]
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0)
                let record: [String: Any] = [
                    "phase": phase, "language": language,
                    "rawTitle": scoped.title, "renderedTitles": model.metrics.map(\.title),
                ]
                try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("weekly-\(language)-\(phase).json"))
            }
        }
    }
}
