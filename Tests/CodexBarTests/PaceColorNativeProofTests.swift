import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class PaceColorNativeProofTests: XCTestCase {
    private static let phases = [
        "default-off", "on", "leading-icon", "stale", "high-contrast", "stale-high-contrast", "multiline", "off-again",
    ]

    func test_paceColorsInStatusItemAndSettings() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_PACE_COLOR_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PACE_COLOR_PROOF_DIR for signed synthetic UI proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil,
              NSHomeDirectory().hasPrefix(output.deletingLastPathComponent().path + "/")
        else { return XCTFail("Use a contained home and credential/session isolation") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = InMemoryUserDefaults()
        defaults.set(MenuBarDisplayMode.both.rawValue, forKey: "menuBarDisplayMode")
        let settings = testSettingsStore(
            suiteName: "PaceColorNativeProof",
            userDefaults: defaults,
            config: testConfigWithAllProvidersDisabled())
        defer { settings.configFileWatcher?.stop() }
        settings.menuBarIconStyle = .iconAndPercent
        let oldResolution = settings.menuBarLayoutResolution(for: .codex)
        XCTAssertTrue(oldResolution.usesLegacyRendering)
        XCTAssertFalse(settings.menuBarColorPace)
        XCTAssertFalse(settings.hasStoredMenuBarLayout)
        let store = self.makeStore(root: root, settings: settings)
        defer { store.stopSharedSpendDashboardPublication() }

        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 850),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar — Synthetic Pace Color Proof"
        host.isReleasedWhenClosed = false
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let button = try XCTUnwrap(item.button)
        button.setAccessibilityIdentifier("codexbar-synthetic-pace-color-proof")
        defer {
            NSStatusBar.system.removeStatusItem(item)
            host.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        let data = MenuBarLayoutRendererTests().data(accountLabel: nil)
        let renderer = MenuBarLayoutRenderer()
        let icon = try XCTUnwrap(NSImage(systemSymbolName: "gauge", accessibilityDescription: "Synthetic provider"))
        icon.isTemplate = true
        // This flag changes assertions only. The baseline must be packaged with the actual old renderer.
        let baseline = environment["CODEXBAR_PACE_COLOR_PROOF_BASELINE"] == "1"
        var receipts: [[String: Any]] = []
        let paceTokens: [MenuBarLayoutToken] = [
            .pace(window: .session), .pace(window: .weekly), .pace(window: .automatic),
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.appearance = appearance
            button.appearance = appearance
            for phase in Self.phases {
                let enabled = phase != "default-off" && phase != "off-again"
                settings.menuBarColorPace = enabled
                settings.menuBarHighContrastOnInactiveDisplays = phase.contains("high-contrast")
                XCTAssertEqual(defaults.bool(forKey: "menuBarColorPace"), enabled)
                XCTAssertEqual(settings.menuBarLayoutResolution(for: .codex), oldResolution)
                XCTAssertFalse(settings.hasStoredMenuBarLayout)
                XCTAssertEqual(defaults.string(forKey: "menuBarDisplayMode"), MenuBarDisplayMode.both.rawValue)
                let lines: [[MenuBarLayoutToken]] = switch phase {
                case "leading-icon": [[.icon] + paceTokens]
                case "multiline": [[.pace(window: .session)], [.pace(window: .weekly), .pace(window: .automatic)]]
                default: [paceTokens]
                }
                let rendered = renderer.render(
                    layout: MenuBarLayout(lines: lines),
                    data: data,
                    icon: phase == "leading-icon" ? icon : nil,
                    options: MenuBarLayoutRenderOptions(
                        size: .regular,
                        highContrast: phase.contains("high-contrast"),
                        showUsed: true,
                        conditionals: [],
                        appearanceName: appearanceName.rawValue,
                        isDebugApp: false,
                        isStale: phase.contains("stale"),
                        now: Date(timeIntervalSince1970: 1_788_000_000),
                        colorPace: enabled))
                item.length = StatusItemController.applyMenuBarLayoutContent(rendered, for: button, gap: .regular)
                guard self.validate(rendered, button: button, phase: phase, enabled: enabled, baseline: baseline) else {
                    return
                }
                host.contentView = NSHostingView(rootView: self.proofView(
                    rendered: rendered,
                    settings: settings,
                    store: store,
                    phase: phase,
                    dark: appearanceName == .darkAqua))
                host.center()
                host.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.7))
                let stem = "pace-\(appearanceName.rawValue)-\(phase)"
                try self.capture(window: host, output: output.appendingPathComponent("\(stem)-settings.png"))
                let statusWindow = try XCTUnwrap(button.window)
                let buttonRect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
                // Capture only the visible button, never its enclosing menu bar or unrelated desktop.
                guard statusWindow.windowNumber > 0, statusWindow.isVisible,
                      !button.isHiddenOrHasHiddenAncestor,
                      NSScreen.screens.contains(where: { $0.frame.contains(buttonRect) }),
                      statusWindow.frame.contains(buttonRect),
                      buttonRect.width <= item.length + 20,
                      buttonRect.height <= 48,
                      buttonRect.width > 0, buttonRect.height > 0
                else { return XCTFail("The native status item did not expose a narrowly bounded onscreen button") }
                try self.capture(
                    window: statusWindow,
                    output: output.appendingPathComponent("\(stem)-status.png"),
                    buttonRect: buttonRect)
                receipts.append([
                    "appearance": appearanceName.rawValue,
                    "phase": phase,
                    "enabled": enabled,
                    "baseline": baseline,
                    "title": rendered.attributedTitle.string,
                    "actualTitle": button.attributedTitle.string,
                    "template": button.image?.isTemplate ?? false,
                    "statusImage": rendered.statusImage != nil,
                    "width": item.length,
                    "statusWindow": statusWindow.windowNumber,
                    "statusFrame": NSStringFromRect(statusWindow.frame),
                    "buttonFrame": NSStringFromRect(buttonRect),
                    "legacyLayoutUnchanged": settings.menuBarLayoutResolution(for: .codex) == oldResolution,
                ])
            }
        }
        let restored = testSettingsStore(
            suiteName: "PaceColorNativeProof-restored",
            userDefaults: defaults,
            config: testConfigWithAllProvidersDisabled())
        defer { restored.configFileWatcher?.stop() }
        XCTAssertFalse(restored.menuBarColorPace)
        XCTAssertEqual(restored.menuBarDisplayMode, .both)
        try JSONSerialization.data(withJSONObject: receipts, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("pace-color-state.json"), options: .atomic)
    }

    private func proofView(
        rendered: MenuBarLayoutRenderedTitle,
        settings: SettingsStore,
        store: UsageStore,
        phase: String,
        dark: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synthetic pace: −8% reserve · +11% ahead · 0% on pace")
                .font(.headline)
            Text("Phase: \(phase) · actual status item and production Settings pane")
            MenuBarLayoutPreviewText(rendered: rendered)
                .frame(height: 42)
            MenuBarPane(settings: settings, store: store)
        }
        .padding(20)
        .preferredColorScheme(dark ? .dark : .light)
    }

    private func makeStore(root: URL, settings: SettingsStore) -> UsageStore {
        let isolated = ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("codex").path]
        settings._test_codexReconciliationEnvironment = isolated
        let store = UsageStore(
            fetcher: UsageFetcher(environment: isolated),
            browserDetection: BrowserDetection(
                homeDirectory: root.path,
                cacheTTL: 0,
                now: Date.init,
                fileExists: { _ in false },
                directoryContents: { _ in nil },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in nil }),
            costUsageFetcher: CostUsageFetcher(cacheRoot: root.appendingPathComponent("cost")),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: root.appendingPathComponent("history")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
            startupBehavior: .testing,
            environmentBase: isolated,
            widgetSnapshotURL: root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})
        store._test_providerRefreshOverride = { _ in XCTFail("Unexpected provider transport") }
        store._test_widgetSnapshotSaveOverride = { _ in }
        return store
    }

    private func validate(
        _ rendered: MenuBarLayoutRenderedTitle,
        button: NSButton,
        phase: String,
        enabled: Bool,
        baseline: Bool) -> Bool
    {
        let templateExpected = !enabled || (baseline && phase == "on")
        XCTAssertEqual(rendered.statusImage != nil, templateExpected)
        XCTAssertEqual(button.image?.isTemplate == true, templateExpected || phase == "leading-icon")
        if !templateExpected {
            XCTAssertTrue(button.attributedTitle.isEqual(to: rendered.attributedTitle))
        }
        for (text, color) in [("-8%", NSColor.systemGreen), ("+11%", NSColor.systemRed)] {
            let range = (rendered.attributedTitle.string as NSString).range(of: text)
            guard range.location != NSNotFound, range.length > 0 else {
                XCTFail("Missing synthetic pace text: \(text)")
                return false
            }
            let actual = rendered.attributedTitle.attribute(
                .foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            let dimmed = phase.contains("stale") && (baseline || !phase.contains("high-contrast"))
            let paceColor = dimmed ? color.withAlphaComponent(0.5) : color
            let expected = enabled ? paceColor : .controlTextColor
            XCTAssertEqual(actual, expected)
        }
        let zeroRange = (rendered.attributedTitle.string as NSString).range(of: "0%")
        guard zeroRange.location != NSNotFound, zeroRange.length > 0 else {
            XCTFail("Missing synthetic zero pace text")
            return false
        }
        let zeroColor = rendered.attributedTitle.attribute(
            .foregroundColor, at: zeroRange.location, effectiveRange: nil) as? NSColor
        let neutral: NSColor = switch phase {
        case "high-contrast", "stale-high-contrast": .labelColor
        case "stale": .secondaryLabelColor
        default: .controlTextColor
        }
        XCTAssertEqual(zeroColor, neutral)
        return true
    }

    private func capture(window: NSWindow, output: URL, buttonRect: NSRect? = nil) throws {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if let buttonRect {
            let screen = try XCTUnwrap(NSScreen.screens.first)
            // Round inward so the requested pixel region never includes neighboring status items.
            let x = Int(ceil(buttonRect.minX))
            let y = Int(ceil(screen.frame.maxY - buttonRect.maxY))
            let width = Int(floor(buttonRect.maxX)) - x
            let height = Int(floor(screen.frame.maxY - buttonRect.minY)) - y
            guard width > 0, height > 0 else {
                throw NSError(domain: "PaceColorNativeProof", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The status button has no capturable pixel region",
                ])
            }
            capture.arguments = ["-x", "-R", "\(x),\(y),\(width),\(height)", output.path]
        } else {
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
        }
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else {
            throw NSError(domain: "PaceColorNativeProof", code: Int(capture.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Native capture failed for \(output.lastPathComponent)",
            ])
        }
    }
}
