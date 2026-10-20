import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SwitcherExhaustedQuotaTests {
    @Test(arguments: [false, true])
    func `automatic switcher shows exhausted rolling and monthly allowances`(_ showUsed: Bool) {
        let cases: [(Double, Double?, Double)] = [(20, 40, 100), (20, nil, 100), (100, 40, 30)]
        for (rolling, weekly, monthly) in cases {
            let snapshot = Self.snapshot(rolling: rolling, weekly: weekly, monthly: monthly)
            let percent = StatusItemController.switcherWeeklyMetricPercent(
                for: .opencodego,
                snapshot: snapshot,
                showUsed: showUsed)
            #expect(percent == (showUsed ? 100 : 0))
        }
    }

    @Test(arguments: [false, true])
    func `automatic switcher shows the most constrained healthy allowance`(_ showUsed: Bool) {
        let cases: [(Double, Double?, Double, Int)] = [
            (20, 40, 90, 43200), (20, nil, 90, 43200), (90, 40, 30, 300), (20, 90, 30, 10080),
        ]
        for (rolling, weekly, monthly, minutes) in cases {
            let snapshot = Self.snapshot(rolling: rolling, weekly: weekly, monthly: monthly)
            let percent = StatusItemController.switcherWeeklyMetricPercent(
                for: .opencodego,
                snapshot: snapshot,
                showUsed: showUsed)
            #expect(percent == (showUsed ? 90 : 10))
            let metric = MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: .opencodego,
                snapshot: snapshot,
                supportsAverage: false)
            #expect(metric?.usedPercent == 90)
            #expect(metric?.windowMinutes == minutes)
        }
    }

    @Test
    func `automatic switcher preserves weekly progress when weekly is most constrained`() {
        let percent = StatusItemController.switcherWeeklyMetricPercent(
            for: .opencodego,
            snapshot: Self.snapshot(monthly: 30),
            showUsed: false)
        #expect(percent == 60)
    }

    @Test(arguments: [MenuBarMetricPreference.primary, .secondary, .tertiary])
    func `explicit preferences retain the existing weekly switcher contract`(_ preference: MenuBarMetricPreference) {
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .opencodego,
            snapshot: Self.snapshot(monthly: 100),
            showUsed: false,
            preference: preference) == 60)
    }

    @Test(arguments: [UsageProvider.claude, .codex, .factory, .kimi, .litellm])
    func `provider policies retain separate tertiary pools`(_ provider: UsageProvider) {
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: provider,
            snapshot: Self.snapshot(monthly: 100),
            showUsed: false) == 60)
    }

    @MainActor
    @Test
    func `native switcher empties the exhausted bar and restores weekly progress after refresh`() throws {
        var snapshot = Self.snapshot(monthly: 100)
        let view = Self.switcher(snapshot: { snapshot })
        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        #expect(view._test_quotaIndicatorFillRatios().last == 0)
        #expect(view._test_quotaIndicatorFillFrames().last?.width == 0)

        snapshot = Self.snapshot(monthly: 30)
        view.updateQuotaIndicators()
        view.layoutSubtreeIfNeeded()
        #expect(view._test_quotaIndicatorFillRatios().last == 0.6)
        #expect(try #require(view._test_quotaIndicatorFillFrames().last).width > 0)
    }

    @MainActor
    @Test
    func `render synthetic constrained quota switcher`() throws {
        guard let output = ProcessInfo.processInfo.environment["CODEXBAR_SWITCHER_QUOTA_PROOF_PATH"] else { return }
        let snapshot = Self.snapshot(monthly: 90)
        let view = Self.switcher(snapshot: { snapshot })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        container.appearance = NSAppearance(named: .aqua)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        let title = NSTextField(labelWithString: "OpenCode Go — monthly quota is tightest")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 20, y: 111, width: 380, height: 22)
        let detail = NSTextField(labelWithString: "Used: rolling 20% · weekly 40% · monthly 90%")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 20, y: 83, width: 380, height: 20)
        view.frame.origin = NSPoint(x: 20, y: 33)
        container.addSubview(title)
        container.addSubview(detail)
        container.addSubview(view)
        container.updateConstraintsForSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        let ratio = try #require(view._test_quotaIndicatorFillRatios().last)
        let frame = try #require(view._test_quotaIndicatorFillFrames().last)
        #expect(ratio.isFinite && frame.width.isFinite)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 840,
            pixelsHigh: 300,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = container.bounds.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        container.displayIgnoringOpacity(container.bounds, in: context)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        print("[switcher-quota-proof] remaining_fill=\(ratio) fill_width=\(frame.width) image=\(output)")
    }

    private static func snapshot(
        rolling: Double = 20,
        weekly: Double? = 40,
        monthly: Double) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(usedPercent: rolling, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: weekly.map {
                RateWindow(usedPercent: $0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
            },
            tertiary: RateWindow(usedPercent: monthly, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_788_480_000))
    }

    @MainActor
    private static func switcher(snapshot: @escaping () -> UsageSnapshot) -> ProviderSwitcherView {
        ProviderSwitcherView(
            providers: [.claude, .opencodego],
            selected: .provider(.opencodego),
            includesOverview: false,
            width: 380,
            showsIcons: false,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { provider in
                provider == .opencodego
                    ? StatusItemController.switcherWeeklyMetricPercent(
                        for: .opencodego,
                        snapshot: snapshot(),
                        showUsed: false)
                    : 60
            },
            onSelect: { _ in })
    }
}
