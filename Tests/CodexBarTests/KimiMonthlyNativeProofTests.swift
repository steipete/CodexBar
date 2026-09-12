import AppKit
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class KimiMonthlyNativeProofTests: XCTestCase {
    func test_monthlyStatusIndicator() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_KIMI_MONTHLY_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_KIMI_MONTHLY_PROOF_DIR for signed synthetic UI proof")
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
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let weekly = RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let session = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let monthly = RateWindow(
            usedPercent: 100,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: nil,
            resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: weekly,
            secondary: session,
            extraRateWindows: [NamedRateWindow(id: "kimi-monthly", title: "Total usage", window: monthly)],
            updatedAt: now)
        let automatic = try XCTUnwrap(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .kimi, snapshot: snapshot, supportsAverage: false, now: now))
        // This flag changes expectations only; capture the baseline using the actual old descriptor binary.
        let baseline = environment["CODEXBAR_KIMI_MONTHLY_PROOF_BASELINE"] == "1"
        XCTAssertEqual(automatic, baseline ? session : monthly)
        let data = MenuBarLayoutRenderData(
            provider: .kimi,
            iconKey: "kimi",
            providerName: "Kimi",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .kimi, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(weekly),
            secondary: MenuBarLayoutRenderWindow(session),
            tertiary: nil,
            session: MenuBarLayoutRenderWindow(session),
            weekly: MenuBarLayoutRenderWindow(weekly),
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: MenuBarLayoutRenderWindow(automatic),
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 310),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar — Synthetic Kimi Monthly Usage"
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
        var receipt: [String: Any] = ["baseline": baseline, "usedPercent": automatic.usedPercent]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearanceName)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 310))
            host.contentView = content
            func label(_ text: String, y: CGFloat, size: CGFloat = 14) {
                let field = NSTextField(labelWithString: text)
                field.font = .systemFont(ofSize: size)
                field.frame = NSRect(x: 28, y: y, width: 660, height: 28)
                content.addSubview(field)
            }
            label(
                baseline ? "Before: monthly exhaustion hidden" : "After: exhausted monthly pool selected",
                y: 260,
                size: 21)
            label("Synthetic quotas: monthly 100% used · Code 7-day and 5-hour 0% used", y: 220)
            label("Production menu-bar renderer · Automatic metric", y: 186)
            for (index, showUsed) in [false, true].enumerated() {
                let rendered = MenuBarLayoutRenderer().render(
                    layout: MenuBarLayout(lines: [[
                        .providerName,
                        .space,
                        .percent(window: .automatic),
                        .space,
                        .usageBar,
                    ]]),
                    data: data,
                    icon: nil,
                    options: MenuBarLayoutRenderOptions(
                        size: .regular,
                        highContrast: false,
                        showUsed: showUsed,
                        conditionals: [],
                        appearanceName: appearanceName.rawValue,
                        isDebugApp: false,
                        now: now))
                let expectedPercent = showUsed ? automatic.usedPercent : automatic.remainingPercent
                let expectedBar = expectedPercent == 100 ? "▮▮▮" : "▯▯▯"
                XCTAssertEqual(rendered.attributedTitle.string, "Kimi \(Int(expectedPercent))% \(expectedBar)")
                let rowY = CGFloat(132 - index * 50)
                label(showUsed ? "Used" : "Remaining", y: rowY)
                if let image = rendered.statusImage {
                    let imageView = NSImageView(image: image)
                    imageView.imageScaling = .scaleNone
                    imageView.imageAlignment = .alignLeft
                    imageView.frame = NSRect(x: 230, y: rowY, width: 420, height: 28)
                    content.addSubview(imageView)
                } else {
                    let field = NSTextField(labelWithAttributedString: rendered.attributedTitle)
                    field.frame = NSRect(x: 230, y: rowY, width: 420, height: 28)
                    content.addSubview(field)
                }
                receipt[showUsed ? "usedTitle" : "remainingTitle"] = rendered.attributedTitle.string
                receipt[showUsed ? "usedStatusImage" : "remainingStatusImage"] = rendered.statusImage != nil
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x", "-o", "-l", String(host.windowNumber),
                output.appendingPathComponent("kimi-\(appearanceName.rawValue).png").path,
            ]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }
}
