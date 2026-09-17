import AppKit
import Observation
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class OpenCodeMonthlyPickerProofTests: XCTestCase {
    private var pending: (window: NSWindow, popup: NSPopUpButton, output: URL, selection: String?)?
    private var capturedOptions: [String] = []

    func test_monthlySelectionUsesRealRendererAndUnavailableState() {
        let model = MonthlyPickerProofModel()
        model.layout = MenuBarPercentWindowPreference.tertiary.applied(to: MenuBarLayout(lines: [[
            .percent(window: .session),
        ]]))
        XCTAssertEqual(model.rendered.attributedTitle.string, "79%")
        XCTAssertEqual(model.rendered.accessibilityLabel, "Monthly 79%")
        model.showUsed = true
        XCTAssertEqual(model.rendered.attributedTitle.string, "21%")
        XCTAssertEqual(model.rendered.accessibilityLabel, "Monthly 21%")
        model.tertiaryAvailable = false
        XCTAssertEqual(model.rendered.attributedTitle.string, "–")
        XCTAssertEqual(model.rendered.accessibilityLabel, "Monthly unavailable")
    }

    func test_syntheticMonthlyPicker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_MONTHLY_PICKER_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_MONTHLY_PICKER_PROOF_DIR for signed synthetic picker proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Use an isolated test host") }
        let baseline = environment["CODEXBAR_MONTHLY_PICKER_PROOF_PHASE"] == "before"
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let model = MonthlyPickerProofModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 390),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic OpenCode Monthly Picker"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: MonthlyPickerProofView(model: model))
        window.contentView = hosting
        defer {
            self.pending?.popup.menu?.cancelTracking()
            self.pending = nil
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
        self.flush(window)
        let popup = try XCTUnwrap(Self.popup(in: hosting), "Expected the production Picker's native control")
        try self.openAndChoose(
            popup,
            window: window,
            output: output.appendingPathComponent("options.png"),
            selection: baseline ? nil : "Monthly")
        let monthlyOptions = self.capturedOptions
        XCTAssertEqual(monthlyOptions.contains("Monthly"), !baseline)
        if !baseline {
            XCTAssertEqual(model.layout.lines[0][0], .lanePercent(lane: .tertiary))
            XCTAssertTrue(model.rendered.attributedTitle.string.contains("79%"))
            XCTAssertTrue(model.rendered.accessibilityLabel.contains("Monthly 79%"))
        }
        try self.capture(window, to: output.appendingPathComponent("selected.png"), includeMenu: false)
        let selectedTitle = model.rendered.attributedTitle.string
        if !baseline {
            let updatedPopup = try XCTUnwrap(Self.popup(in: hosting))
            try self.openAndChoose(
                updatedPopup,
                window: window,
                output: output.appendingPathComponent("weekly-options.png"),
                selection: "Weekly")
            XCTAssertEqual(model.layout.lines[0][0], .percent(window: .weekly))
            XCTAssertTrue(model.rendered.attributedTitle.string.contains("100%"))
            XCTAssertTrue(model.layout.lines[0].contains(.pace(window: .weekly)))
            try self.capture(window, to: output.appendingPathComponent("weekly.png"), includeMenu: false)
        }
        try JSONSerialization.data(withJSONObject: [
            "syntheticOnly": true,
            "baseline": baseline,
            "options": monthlyOptions,
            "selectedTitle": selectedTitle,
            "finalTitle": model.rendered.attributedTitle.string,
            "finalPreference": MenuBarPercentWindowPreference.current(in: model.layout)?.rawValue ?? "custom",
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("state.json"))
    }

    private func openAndChoose(
        _ popup: NSPopUpButton,
        window: NSWindow,
        output: URL,
        selection: String?) throws
    {
        self.pending = (window, popup, output, selection)
        self.capturedOptions = []
        let timer = Timer(
            timeInterval: 1, target: self, selector: #selector(self.captureAndChoose), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        popup.performClick(nil)
        timer.invalidate()
        self.pending = nil
        self.flush(window)
        XCTAssertFalse(self.capturedOptions.isEmpty)
    }

    @objc private func captureAndChoose() {
        guard let pending = self.pending else { return }
        defer { pending.popup.menu?.cancelTracking() }
        self.capturedOptions = pending.popup.itemTitles
        do {
            try self.capture(pending.window, to: pending.output, includeMenu: true)
            if let selection = pending.selection,
               let menu = pending.popup.menu,
               let index = menu.items.firstIndex(where: { $0.title == selection })
            {
                pending.popup.selectItem(at: index)
                menu.performActionForItem(at: index)
            }
        } catch {
            XCTFail("Synthetic picker capture failed: \(error)")
        }
    }

    private func capture(_ window: NSWindow, to output: URL, includeMenu: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if includeMenu {
            let screen = try XCTUnwrap(NSScreen.screens.first)
            let frame = window.frame
            let rectangle = "\(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY))," +
                "\(Int(frame.width)),\(Int(frame.height))"
            process.arguments = ["-x", "-R", rectangle, output.path]
        } else {
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
        }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func flush(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    }

    private static func popup(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        return view.subviews.lazy.compactMap { Self.popup(in: $0) }.first
    }
}

@MainActor
@Observable
private final class MonthlyPickerProofModel {
    var layout = MenuBarLayout(lines: [[.percent(window: .session), .separatorDot, .pace(window: .weekly)]])
    var showUsed = false
    var tertiaryAvailable = true
    private let renderer = MenuBarLayoutRenderer()

    var rendered: MenuBarLayoutRenderedTitle {
        let primary = MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil))
        let secondary = MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))
        let tertiary = self.tertiaryAvailable ? MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: 21, windowMinutes: 43200, resetsAt: nil, resetDescription: nil)) : nil
        let data = MenuBarLayoutRenderData(
            provider: .opencodego,
            iconKey: "synthetic-monthly",
            providerName: nil,
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .opencodego, snapshot: nil),
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            session: primary,
            weekly: secondary,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: primary,
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
        return self.renderer.render(
            layout: self.layout,
            data: data,
            icon: nil,
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: self.showUsed,
                conditionals: [],
                appearanceName: NSAppearance.Name.aqua.rawValue,
                isDebugApp: false,
                now: Date(timeIntervalSince1970: 1_700_000_000)))
    }
}

@MainActor
private struct MonthlyPickerProofView: View {
    @Bindable var model: MonthlyPickerProofModel

    var body: some View {
        Form {
            Text("OpenCode Go · Synthetic quotas").font(.headline)
            ProviderMenuBarPercentWindowPicker(
                provider: .opencodego,
                iconStyle: .iconAndPercent,
                layout: self.$model.layout)
            Section("Menu bar preview") {
                MenuBarLayoutPreviewText(rendered: self.model.rendered)
                    .frame(height: 35)
                Text("5-hour: 100% left · Weekly: 100% left · Monthly: 79% left")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, Locale(identifier: "en"))
        .frame(width: 640, height: 390)
    }
}
