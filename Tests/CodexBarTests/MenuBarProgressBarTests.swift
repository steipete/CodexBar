import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MenuBarProgressBarTests {
    @Test
    func `progress bar token labels by window and stacks as a preset`() throws {
        let sessionBar = MenuBarLayoutToken.progressBar(window: .session)
        let weeklyBar = MenuBarLayoutToken.progressBar(window: .weekly)

        let encoded = try JSONEncoder().encode(sessionBar)
        #expect(try JSONDecoder().decode(MenuBarLayoutToken.self, from: encoded) == sessionBar)
        #expect(sessionBar.editorLabel(provider: .codex) == L("%@ %@", L("Session"), L("menu_bar_layout_token_bar")))
        #expect(weeklyBar.editorLabel(provider: .codex) == L("%@ %@", L("Weekly"), L("menu_bar_layout_token_bar")))
        #expect(MenuBarLayoutPreset.barsStacked.layout == MenuBarLayout(lines: [
            [.progressBar(window: .session), .windowResetCountdown(window: .session)],
            [.progressBar(window: .weekly), .windowResetCountdown(window: .weekly)],
        ]))

        let barsStacked = try #require(MenuBarLayoutPreset.barsStacked.layout)
        let percentages = MenuBarLayout(lines: [[.percent(window: .session)], [.percent(window: .weekly)]])
        #expect(barsStacked.releasedCompatible() == percentages)
        #expect(barsStacked.legacyCompatible() == percentages)
        #expect(barsStacked.v3Compatible() == MenuBarLayout(lines: [
            [.percent(window: .session), .windowResetCountdown(window: .session)],
            [.percent(window: .weekly), .windowResetCountdown(window: .weekly)],
        ]))
    }

    @Test
    func `estimated progress bars preserve the accessible estimate marker`() {
        let fixture = MenuBarLayoutRendererTests()
        var data = fixture.data()
        data.quotaIsEstimated = true
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.progressBar(window: .session)]]),
            data: data,
            icon: nil,
            options: fixture.options())

        #expect(output.accessibilityLabel == L("%@ %@", L("Session"), "~25%"))
    }

    @Test
    func `automatic balance bars suppress duplicate resets including conditional branches`() {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        var rule = MenuBarLayoutConditional.makeDefault()
        rule.thenToken = .progressBar(window: .automatic)
        rule.elseToken = rule.thenToken
        let balance = fixture.data(
            provider: .deepseek, automaticText: "¥100.00", automaticBalanceFallback: "¥100.00")
        for token in [MenuBarLayoutToken.progressBar(window: .automatic), .conditional(id: rule.id)] {
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[token, .separatorDot, .resetCountdown]]),
                data: balance,
                icon: nil,
                options: fixture.options(conditionals: [rule]))
            #expect(output.attributedTitle.string == "¥100.00")
        }
        let resetOnly = renderer.render(
            layout: MenuBarLayout(lines: [[.resetCountdown]]),
            data: balance,
            icon: nil,
            options: fixture.options())
        #expect(resetOnly.attributedTitle.string == "¥100.00")
        let dated = renderer.render(
            layout: MenuBarLayout(lines: [[.progressBar(window: .automatic), .resetCountdown]]),
            data: fixture.data(automaticText: "¥100.00"),
            icon: nil,
            options: fixture.options())
        #expect(dated.attributedTitle.string == "¥100.00\u{2009}in 2h")
    }

    @Test
    func `progress bar redraws changed usage and remaining mode in light and dark appearances`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.progressBar(window: .automatic)]])
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var result: Result<Void, Error> = .success(())
            appearance.performAsCurrentDrawingAppearance {
                result = Result {
                    @MainActor
                    func image(percent: Double, showUsed: Bool) throws -> Data {
                        let result = renderer.render(
                            layout: layout,
                            data: fixture.data(automaticUsedPercent: percent),
                            icon: nil,
                            options: fixture.options(showUsed: showUsed, appearanceName: name.rawValue))
                        let attachment = try #require(result.attributedTitle.attribute(
                            .attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
                        return try #require(attachment.image?.tiffRepresentation)
                    }
                    let low = try image(percent: 20, showUsed: true)
                    let high = try image(percent: 80, showUsed: true)
                    #expect(low != high)
                    #expect(try image(percent: 80, showUsed: false) == low)
                    #expect(try image(percent: 20, showUsed: true) == low)
                }
            }
            try result.get()
        }
    }

    @Test
    func `pill bar style draws a continuous meter without changing text or accessibility`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.progressBar(window: .weekly)]])

        func render(_ style: MenuBarLayoutBarStyle, percent: Double = 50) throws
            -> (output: MenuBarLayoutRenderedTitle, image: NSImage)
        {
            let output = renderer.render(
                layout: layout,
                data: fixture.data(weeklyUsedPercent: percent),
                icon: nil,
                options: fixture.options(barStyle: style))
            let text = output.attributedTitle.string
            let index = try #require(text.firstIndex(of: "\u{FFFC}"))
            let attachment = try #require(output.attributedTitle.attribute(
                .attachment,
                at: text.distance(from: text.startIndex, to: index),
                effectiveRange: nil) as? NSTextAttachment)
            let image = try #require(attachment.image)
            return (output, image)
        }

        let segmented = try render(.segmented)
        let pill = try render(.pill)
        #expect(pill.output.attributedTitle.string == segmented.output.attributedTitle.string)
        #expect(pill.output.accessibilityLabel == segmented.output.accessibilityLabel)
        #expect(pill.image.size == segmented.image.size)
        #expect(pill.image.tiffRepresentation != segmented.image.tiffRepresentation)
        #expect(try render(.pill, percent: 80).image.tiffRepresentation != pill.image.tiffRepresentation)
        #expect(MenuBarLayoutBarStyle(rawValue: "pill") == .pill)
        #expect(MenuBarLayoutBarStyle.allCases == [.segmented, .pill])
    }
}
