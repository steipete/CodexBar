import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Developer tool, skipped by default: renders the capsule and battery usage bar styles side by side
/// to PNGs for documentation and pull requests.
///
/// The renders use an isolated settings store, so they never read the developer's own config, never
/// write to the shared App Group, and never touch the Keychain.
///
/// Run with:
///   CODEXBAR_BATTERY_SCREENSHOT_DIR=~/Downloads swift test --filter UsageBarBatteryScreenshotRenderTests
@MainActor
final class UsageBarBatteryScreenshotRenderTests: XCTestCase {
    private static let barWidth: CGFloat = 320
    private static let percents: [Double] = [88, 67, 42, 23, 5]

    func test_renderUsageBarStyleScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_BATTERY_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_BATTERY_SCREENSHOT_DIR to render usage bar style screenshots.")
        }
        let directory = URL(
            fileURLWithPath: NSString(string: dir).expandingTildeInPath,
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let renders: [(String, AnyView)] = [
            ("usage-bar-style-remaining", AnyView(Self.comparison(showsUsed: false))),
            ("usage-bar-style-used", AnyView(Self.comparison(showsUsed: true))),
            ("usage-bar-style-highlighted", AnyView(Self.highlightedComparison())),
        ]

        for (name, view) in renders {
            let data = try XCTUnwrap(Self.pngData(for: view), "render failed for \(name)")
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    /// Capsule keeps the provider tint; battery recolors by how much quota is left.
    private static func comparison(showsUsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(showsUsed ? "Used mode (bar fills with consumption)" : "Remaining mode (bar fills with quota left)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 28) {
                self.column(title: "Capsule", style: .capsule, showsUsed: showsUsed)
                self.column(title: "Battery", style: .battery, showsUsed: showsUsed)
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func column(title: String, style: UsageBarStyle, showsUsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(self.percents, id: \.self) { percent in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(percent))%").font(.caption).foregroundStyle(.secondary)
                    UsageProgressBar(
                        percent: percent,
                        tint: Color(nsColor: .systemGreen),
                        accessibilityLabel: "\(Int(percent)) percent",
                        usageBarStyle: style,
                        showsUsed: showsUsed)
                        .frame(width: self.barWidth)
                }
            }
        }
    }

    /// A selected menu row must keep its contrast instead of dropping to the severity palette.
    private static func highlightedComparison() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Highlighted menu row").font(.headline)
            ForEach(self.percents, id: \.self) { percent in
                UsageProgressBar(
                    percent: percent,
                    tint: Color(nsColor: .systemGreen),
                    accessibilityLabel: "\(Int(percent)) percent",
                    usageBarStyle: .battery)
                    .frame(width: self.barWidth)
                    .environment(\.menuItemHighlighted, true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MenuHighlightStyle.selectionBackground(true))
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Renders through an offscreen window so the Canvas draws into a real backing store.
    private static func pngData(for view: AnyView) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }

    /// Menu-bar counterpart: renders the real status-item title so the graphical meters can be
    /// compared at their actual 5-7pt height.
    ///
    /// Run with:
    ///   CODEXBAR_MENUBAR_BATTERY_SCREENSHOT_DIR=~/Downloads swift test --filter UsageBarBatteryScreenshotRenderTests
    func test_renderMenuBarBatteryStyleScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_MENUBAR_BATTERY_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_MENUBAR_BATTERY_SCREENSHOT_DIR to render menu bar style screenshots.")
        }
        let directory = URL(
            fileURLWithPath: NSString(string: dir).expandingTildeInPath,
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[
            .progressBar(window: .session),
            .progressBar(window: .weekly),
            .progressBar(window: .scopedWeekly),
            .progressBar(window: .automatic),
        ]])
        let variants: [(name: String, style: UsageBarStyle, highContrast: Bool)] = [
            ("menubar-usage-bar-capsule", .capsule, false),
            ("menubar-usage-bar-battery", .battery, false),
            ("menubar-usage-bar-battery-high-contrast", .battery, true),
        ]
        for variant in variants {
            // `withAlphaComponent` resolves dynamic catalog colors at call time, so the render itself
            // must run under the target appearance or the baked meter colors follow the process default.
            var rendered: MenuBarLayoutRenderedTitle?
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                rendered = renderer.render(
                    layout: layout,
                    data: Self.menuBarData(),
                    icon: nil,
                    options: MenuBarLayoutRenderOptions(
                        size: .regular,
                        highContrast: variant.highContrast,
                        showUsed: false,
                        conditionals: [],
                        appearanceName: "darkAqua",
                        isDebugApp: false,
                        now: Date(timeIntervalSince1970: 1_752_768_000),
                        usageBarStyle: variant.style))
            }
            let title = try XCTUnwrap(rendered?.attributedTitle)
            let data = try XCTUnwrap(
                Self.pngData(title: title, caption: variant.name),
                "render failed for \(variant.name)")
            let url = directory.appendingPathComponent("\(variant.name).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    /// Remaining quota 88 / 42 / 5 / 50 so one row spans all three severity bands.
    private static func menuBarData() -> MenuBarLayoutRenderData {
        MenuBarLayoutRenderData(
            provider: .codex,
            iconKey: "codex",
            providerName: "Codex",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .codex, snapshot: nil),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            session: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
            weekly: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 58, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            scopedWeekly: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 95, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            scopedWeeklyTitle: "Fable only",
            automatic: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
    }

    private static func pngData(title: NSAttributedString, caption: String) -> Data? {
        let scale: CGFloat = 2
        let padding: CGFloat = 16
        let bounds = title.boundingRect(
            with: NSSize(width: 2000, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(
            width: max(420, bounds.width + padding * 2),
            height: padding * 2 + 18 + bounds.height)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        representation.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSAttributedString(
                string: caption,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]).draw(at: NSPoint(x: padding, y: size.height - padding - 14))
            title.draw(in: NSRect(x: padding, y: padding, width: bounds.width, height: bounds.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])
    }
}
