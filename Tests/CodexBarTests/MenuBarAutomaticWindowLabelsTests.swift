import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarAutomaticWindowLabelsTests {
    private let now = Date(timeIntervalSince1970: 1_752_768_000)

    @Test
    func `automatic tokens identify either selected window and honor the label preference`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic)], [.pace(window: .automatic)]])
        for weekly in [false, true] {
            let data = self.data(weekly: weekly)
            let prefix = weekly ? "W" : "5h"
            let visible = renderer.render(layout: layout, data: data, icon: nil, options: self.options())
            #expect(visible.attributedTitle.string == "\(prefix) 84%\n\(prefix) +7%")
            let hidden = renderer.render(
                layout: layout, data: data, icon: nil, options: self.options(showLabels: false))
            #expect(hidden.attributedTitle.string == "84%\n+7%")
            #expect(hidden.accessibilityLabel == visible.accessibilityLabel)
            let cached = renderer.render(
                layout: layout, data: data, icon: nil, options: self.options(now: self.now.addingTimeInterval(1)))
            #expect(cached.attributedTitle === visible.attributedTitle)
        }
    }

    @Test
    func `automatic conditional retains its window label when it switches to reset time`() throws {
        let conditional = try #require(MenuBarLayoutConditional.shippedLibrary().first {
            $0.clauses.contains { $0.predicate.direction == .remaining }
        })
        let layout = MenuBarLayout(lines: [[.conditional(id: conditional.id)]])
        let renderer = MenuBarLayoutRenderer()
        for weekly in [false, true] {
            let prefix = weekly ? "W" : "5h"
            let options = self.options(conditionals: [conditional])
            let available = renderer.render(
                layout: layout,
                data: self.data(weekly: weekly),
                icon: nil,
                options: options)
            #expect(available.attributedTitle.string == "\(prefix) 84%")
            let exhausted = self.data(weekly: weekly, used: 100)
            let reset = renderer.render(layout: layout, data: exhausted, icon: nil, options: options)
            #expect(reset.attributedTitle.string == "\(prefix) in 2h")
            let hidden = renderer.render(
                layout: layout,
                data: exhausted,
                icon: nil,
                options: self.options(showLabels: false, conditionals: [conditional]))
            #expect(hidden.attributedTitle.string == "in 2h")
            let absolute = renderer.render(
                layout: MenuBarLayout(lines: [[.resetAbsolute]]), data: exhausted, icon: nil, options: options)
            #expect(absolute.attributedTitle.string.hasPrefix("\(prefix) "))
        }
    }

    @Test
    func `automatic tokens on one line name their window once`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic), .pace(window: .automatic)]])
        for weekly in [false, true] {
            let data = self.data(weekly: weekly)
            let prefix = weekly ? "W" : "5h"
            let visible = renderer.render(layout: layout, data: data, icon: nil, options: self.options())
            #expect(visible.attributedTitle.string == "\(prefix) 84%\u{2009}+7%")
            let hidden = renderer.render(
                layout: layout, data: data, icon: nil, options: self.options(showLabels: false))
            #expect(hidden.attributedTitle.string == "84%\u{2009}+7%")
            let percent = renderer.render(
                layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
                data: data,
                icon: nil,
                options: self.options())
            let pace = renderer.render(
                layout: MenuBarLayout(lines: [[.pace(window: .automatic)]]),
                data: data,
                icon: nil,
                options: self.options())
            #expect(visible.accessibilityLabel == "\(percent.accessibilityLabel), \(pace.accessibilityLabel)")
        }
    }

    @Test
    func `automatic tokens repeat their label only after another window`() {
        let renderer = MenuBarLayoutRenderer()
        let data = self.data()
        let cases: [([MenuBarLayoutToken], String)] = [
            (
                [.percent(window: .automatic), .percent(window: .weekly), .pace(window: .automatic)],
                "5h 84%\u{2009}W 84%\u{2009}5h +7%"),
            ([.percent(window: .session), .pace(window: .automatic)], "5h 84%\u{2009}+7%"),
            ([.percent(window: .automatic), .space, .resetCountdown], "5h 84% in 2h"),
            ([.percent(window: .automatic), .separatorDot, .resetCountdown], "5h 84%\u{2009}·\u{2009}in 2h"),
        ]
        for (tokens, expected) in cases {
            let output = renderer.render(
                layout: MenuBarLayout(lines: [tokens]), data: data, icon: nil, options: self.options())
            #expect(output.attributedTitle.string == expected)
        }
    }

    @Test
    func `single quota and automatic balance text remain bare`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic)]])
        let single = renderer.render(layout: layout, data: self.data(single: true), icon: nil, options: self.options())
        #expect(single.attributedTitle.string == "84%")
        let balance = renderer.render(
            layout: layout, data: self.data(automaticText: "$12"), icon: nil, options: self.options())
        #expect(balance.attributedTitle.string == "$12")
    }

    @Test
    func `automatic labels include monthly and named provider allowances`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic)], [.pace(window: .automatic)]])
        for (data, label) in [(self.data(monthly: true), "M"), (self.data(namedAllowance: true), "GB")] {
            let output = renderer.render(layout: layout, data: data, icon: nil, options: self.options())
            #expect(output.attributedTitle.string == "\(label) 84%\n\(label) +7%")
        }
    }

    private func data(
        weekly: Bool = false,
        monthly: Bool = false,
        namedAllowance: Bool = false,
        used: Double = 84,
        single: Bool = false,
        automaticText: String? = nil) -> MenuBarLayoutRenderData
    {
        let session = MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: used,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(7200),
            resetDescription: nil))
        let week = single ? nil : MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: used,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(7200),
            resetDescription: nil))
        let month = monthly ? MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: used,
            windowMinutes: 43200,
            resetsAt: self.now.addingTimeInterval(7200),
            resetDescription: nil)) : nil
        let extra = namedAllowance ? MenuBarLayoutRenderExtra(NamedRateWindow(
            id: "cursor-grok-bot",
            title: "Grok Bot",
            window: RateWindow(
                usedPercent: used,
                windowMinutes: nil,
                resetsAt: self.now.addingTimeInterval(7200),
                resetDescription: nil))) : nil
        let provider: UsageProvider = monthly ? .opencodego : namedAllowance ? .cursor : .claude
        return MenuBarLayoutRenderData(
            provider: provider,
            iconKey: "synthetic-auto-label",
            providerName: nil,
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: provider, snapshot: nil),
            primary: session,
            secondary: week,
            tertiary: month,
            extraRateWindows: extra.map { [$0] } ?? [],
            session: session,
            weekly: week,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: extra?.window ?? month ?? (weekly ? week : session),
            automaticText: automaticText,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: "+7%",
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
    }

    private func options(
        showLabels: Bool = true,
        now: Date? = nil,
        conditionals: [MenuBarLayoutConditional] = []) -> MenuBarLayoutRenderOptions
    {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: false,
            showUsed: true,
            conditionals: conditionals,
            appearanceName: "aqua",
            isDebugApp: false,
            now: now ?? self.now,
            showWindowLabels: showLabels)
    }
}
