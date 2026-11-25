import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AntigravityWeeklyLayoutTests {
    @Test(arguments: [false, true])
    func `family weekly tokens render independently and never borrow another quota`(showUsed: Bool) throws {
        let snapshot = try self.snapshot()
        let fixture = MenuBarLayoutRendererTests()
        let tokens = self.tokens
        let extras = (snapshot.extraRateWindows ?? []).map(MenuBarLayoutRenderExtra.init)
        let renderer = MenuBarLayoutRenderer()
        let rendered = renderer.render(
            layout: MenuBarLayout(lines: [tokens]),
            data: fixture.data(provider: .antigravity, extraRateWindows: extras),
            icon: nil,
            options: fixture.options(showUsed: showUsed))
        #expect(rendered.attributedTitle.string == (showUsed ? "Gemini weekly 20%\u{2009}Claude/GPT weekly 60%"
                : "Gemini weekly 80%\u{2009}Claude/GPT weekly 40%"))
        #expect(rendered.accessibilityLabel == (showUsed
                ? "Gemini weekly 20%, Claude/GPT weekly 60%" : "Gemini weekly 80%, Claude/GPT weekly 40%"))
        let missing = renderer.render(
            layout: MenuBarLayout(lines: [tokens]),
            data: fixture.data(provider: .antigravity, extraRateWindows: extras.filter {
                $0.id != "antigravity-quota-summary-gemini-weekly"
            }),
            icon: nil,
            options: fixture.options(showUsed: showUsed))
        #expect(missing.attributedTitle.string == (showUsed
                ? "Gemini weekly –\u{2009}Claude/GPT weekly 60%" : "Gemini weekly –\u{2009}Claude/GPT weekly 40%"))
        let otherProvider = renderer.render(
            layout: MenuBarLayout(lines: [[.lanePercent(lane: .primary)] + tokens]),
            data: fixture.data(provider: .claude, extraRateWindows: extras),
            icon: nil,
            options: fixture.options(showUsed: showUsed))
        #expect(otherProvider.attributedTitle.string == (showUsed ? "10%" : "90%"))
    }

    @Test
    func `family pace chips pace each quota on its own`() throws {
        let store = Self.store()
        let reset = try #require(ISO8601DateFormatter().date(from: "2026-06-19T08:45:39Z"))
        let now = reset.addingTimeInterval(-3.5 * 24 * 60 * 60)
        let data = try store.menuBarLayoutRenderData(
            provider: .antigravity,
            snapshot: self.snapshot(),
            iconKey: "antigravity",
            accountLabel: nil,
            costs: MenuBarLayoutCostValues(today: nil, last30Days: nil, todayUSD: nil, last30DaysUSD: nil),
            now: now)
        let fixture = MenuBarLayoutRendererTests()
        let cases: [(String, String, NSColor)] = [
            ("antigravity-quota-summary-gemini-weekly", "-30%", .systemGreen),
            ("antigravity-quota-summary-3p-weekly", "+19%", .systemRed),
        ]
        for (id, pace, color) in cases {
            let rendered = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[.extraPace(id: id)]]),
                data: data,
                icon: nil,
                options: fixture.options(colorPace: true))
            #expect(rendered.attributedTitle.string.hasSuffix(pace))
            #expect(rendered.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == color)
        }
        let unavailable = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.extraPace(id: "antigravity-quota-summary-gemini-weekly")]]),
            data: fixture.data(provider: .antigravity),
            icon: nil,
            options: fixture.options(colorPace: true))
        #expect(unavailable.accessibilityLabel == "Gemini weekly pace unavailable")
    }

    @Test
    func `synthetic family weekly before and after proof`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_WEEKLY_LAYOUT_PROOF_DIR"] else { return }
        let extras = try (self.snapshot().extraRateWindows ?? []).map(MenuBarLayoutRenderExtra.init)
        let fixture = MenuBarLayoutRendererTests()
        for after in [false, true] {
            let rendered = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: after ? self.tokens.map { [$0] } : [[.percent(window: .weekly)]]),
                data: fixture.data(provider: .antigravity, extraRateWindows: extras),
                icon: nil,
                options: fixture.options(showUsed: false))
            let image = NSImage(size: NSSize(width: 520, height: 130))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 520, height: 130).fill()
            let caption = after ? "After: Gemini weekly / Claude-GPT weekly" : "Before: most constrained weekly"
            ("Antigravity · Synthetic data\n" + caption as NSString).draw(
                at: NSPoint(x: 16, y: 86), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black,
                ])
            let transform = NSAffineTransform()
            transform.scale(by: 2)
            transform.concat()
            let text = NSMutableAttributedString(attributedString: rendered.attributedTitle)
            text.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: text.length))
            text.draw(at: NSPoint(x: 8, y: 8))
            image.unlockFocus()
            let bitmap = try NSBitmapImageRep(data: #require(image.tiffRepresentation))
            let png = try #require(bitmap?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("antigravity-weekly-\(after ? "after" : "before").png"))
        }
    }

    private var tokens: [MenuBarLayoutToken] {
        [
            .extraPercent(id: "antigravity-quota-summary-gemini-weekly"),
            .extraPercent(id: "antigravity-quota-summary-3p-weekly"),
        ]
    }

    private static func store() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "antigravity-family-pace",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        return UsageStore(fetcher: UsageFetcher(), browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
    }

    private func snapshot() throws -> UsageSnapshot {
        let json = antigravityQuotaSummaryJSON(
            geminiSession: 0.1, geminiWeekly: 0.8, claudeSession: 0.2, claudeWeekly: 0.4)
        return try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8)).toUsageSnapshot()
    }
}
