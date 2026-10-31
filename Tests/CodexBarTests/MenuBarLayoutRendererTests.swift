import AppKit
import CodexBarCore
import Foundation
import os
import Testing
@testable import CodexBar

// Token coverage spans many providers; suites share one fixture/helper vocabulary.
// swiftlint:disable file_length

@MainActor
@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct MenuBarLayoutRendererTests {
    let now = Date(timeIntervalSince1970: 1_752_768_000)

    @Test
    func `window label preference hides percentage prefixes without changing accessibility or cached defaults`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[
            .percent(window: .session), .percent(window: .weekly), .percent(window: .scopedWeekly),
            .percent(window: .automatic), .percent(window: .spend),
        ]])
        let visible = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options())
        let hidden = renderer.render(
            layout: layout, data: self.data(), icon: nil, options: self.options(showWindowLabels: false))
        #expect(visible.attributedTitle.string == "5h 25%\u{2009}W 60%\u{2009}F 80%\u{2009}50%\u{2009}$ 46%")
        #expect(hidden.attributedTitle.string == "25%\u{2009}60%\u{2009}80%\u{2009}50%\u{2009}$ 46%")
        #expect(hidden.accessibilityLabel == visible.accessibilityLabel)
        #expect(hidden.attributedTitle !== visible.attributedTitle)
        let restored = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options())
        #expect(restored.attributedTitle === visible.attributedTitle)
    }

    @Test
    func `window label preference handles short unknown and unavailable sessions`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .session)]])
        for minutes in [30, nil] {
            let data = self.data(sessionWindowMinutes: minutes)
            let visible = renderer.render(layout: layout, data: data, icon: nil, options: self.options())
            let hidden = renderer.render(
                layout: layout,
                data: data,
                icon: nil,
                options: self.options(showUsed: false, showWindowLabels: false))
            #expect(visible.attributedTitle.string == (minutes == nil ? "S 25%" : "30m 25%"))
            #expect(hidden.attributedTitle.string == "75%")
            #expect(hidden.accessibilityLabel == L("%@ %@", L("Session"), "75%"))
        }
        let unavailable = renderer.render(
            layout: layout,
            data: self.data(omitsSession: true),
            icon: nil,
            options: self.options(showWindowLabels: false))
        #expect(unavailable.attributedTitle.string == "–")
        #expect(unavailable.accessibilityLabel == L("%@ unavailable", L("Session")))
    }

    @Test
    func `window label preference preserves named provider labels and progress bars`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[
            .percent(window: .session), .percent(window: .weekly), .lanePercent(lane: .tertiary),
            .extraPercent(id: "cursor-grok-bot"), .progressBar(window: .session),
        ]])
        let data = self.data(provider: .cursor)
        let visible = renderer.render(layout: layout, data: data, icon: nil, options: self.options())
        let hidden = renderer.render(
            layout: layout, data: data, icon: nil, options: self.options(showWindowLabels: false))
        #expect(hidden.attributedTitle.string == visible.attributedTitle.string)
        #expect(hidden.accessibilityLabel == visible.accessibilityLabel)
        let bar = renderer.render(
            layout: MenuBarLayout(lines: [[.progressBar(window: .session)]]),
            data: self.data(),
            icon: nil,
            options: self.options(showWindowLabels: false))
        #expect(bar.attributedTitle.string == "5h \u{FFFC}")
    }

    @Test(arguments: [UsageProvider.codex, .claude], [false, true])
    func `provider weekly lane token renders without a window prefix`(provider: UsageProvider, showUsed: Bool) {
        let token = MenuBarLayoutToken.lanePercent(lane: .secondary)
        #expect(MenuBarLayoutPaletteTokens.usage(provider: provider, snapshot: nil).contains(token))
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[token]]),
            data: self.data(provider: provider),
            icon: nil,
            options: self.options(showUsed: showUsed))
        let expected = showUsed ? "9%" : "91%"
        #expect(output.attributedTitle.string == expected)
        #expect(output.accessibilityLabel == L("%@ %@", L("Weekly"), expected))
    }

    @Test
    func `renderer composes every token with live values`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let data = self.data()
        let expected: [(MenuBarLayoutToken, String)] = [
            (.providerName, "Codex"),
            (.accountLabel, "user@example.com"),
            (.percent(window: .session), "5h 25%"),
            (.percent(window: .weekly), "W 60%"),
            (.percent(window: .scopedWeekly), "F 80%"),
            (.percent(window: .automatic), "50%"),
            (.pace(window: .session), "-8%"),
            (.pace(window: .weekly), "+11%"),
            (.pace(window: .automatic), "0%"),
            (.usageBar, "▮▮▯"),
            (.resetCountdown, "in 2h"),
            (.runsOut, "Runs out in 1d 16h"),
            (.runsOutCompact, "1d 16h"),
            (.balance, "$12.34"),
            (.costToday, "$1.25"),
            (.costWindow, "$20.00"),
            (.separatorDot, "·"),
            (.separator(.pipe), "|"),
            (.separator(.slash), "/"),
            (.separator(.hyphen), "-"),
            (.separator(.bullet), "•"),
            (.separator(.diamond), "◆"),
            (.separator(.hollowDiamond), "◇"),
            (.separator(.tilde), "~"),
            (.separator(.doubleBar), "‖"),
            (.space, " "),
        ]

        for (token, value) in expected {
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[token]]),
                data: data,
                icon: icon,
                options: self.options())
            #expect(output.attributedTitle.string == value)
        }

        let iconOutput = renderer.render(
            layout: MenuBarLayout(lines: [[.icon]]),
            data: data,
            icon: icon,
            options: self.options())
        #expect(iconOutput.attributedTitle.string.isEmpty)
        #expect(iconOutput.leadingIcon != nil)

        let absoluteOutput = renderer.render(
            layout: MenuBarLayout(lines: [[.resetAbsolute]]),
            data: data,
            icon: icon,
            options: self.options())
        #expect(absoluteOutput.attributedTitle.string != "–")
    }

    @Test
    func `Notion secondary percentage renders and announces monthly cadence`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .weekly)]]),
            data: self.data(provider: .notion),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "M 60%")
        #expect(output.accessibilityLabel == L("%@ %@", L("Monthly"), "60%"))
    }

    @Test
    func `Cursor lane percentages render independently`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[
                .lanePercent(lane: .primary),
                .lanePercent(lane: .secondary),
                .lanePercent(lane: .tertiary),
            ]]),
            data: self.data(provider: .cursor),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "T 10%\u{2009}C 9%\u{2009}TP 17%")
        #expect(output.accessibilityLabel == "Total 10%, Cursor 9%, Third Party 17%")
    }

    @Test
    func `Cursor semantic percentages reuse explicit lane tags`() {
        let renderer = MenuBarLayoutRenderer()
        let expected: [(PercentWindow, String, String)] = [
            (.session, "T 25%", "Total 25%"),
            (.weekly, "C 60%", "Cursor 60%"),
            (.automatic, "50%", "\(L("Usage")) 50%"),
        ]
        for (window, value, accessibility) in expected {
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[.percent(window: window)]]),
                data: self.data(provider: .cursor),
                icon: nil,
                options: self.options())
            #expect(output.attributedTitle.string == value)
            // Cursor's lanes reset monthly, so the tagged weekly slot must not be announced as "Weekly".
            #expect(output.accessibilityLabel == accessibility)
        }
    }

    @Test
    func `providers without short labels keep bare lane percentages`() {
        let renderer = MenuBarLayoutRenderer()
        for descriptor in ProviderDescriptorRegistry.all where descriptor.menuBarMetrics.laneShortLabels.isEmpty {
            let data = self.data(provider: descriptor.id)
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[.lanePercent(lane: .primary), .lanePercent(lane: .secondary)]]),
                data: data,
                icon: nil,
                options: self.options())
            #expect(output.attributedTitle.string == "10%\u{2009}9%")
            #expect(output.accessibilityLabel == "\(data.laneLabels.primary) 10%, \(data.laneLabels.secondary) 9%")
        }
    }

    @Test
    func `Cursor Grok Bot extra percentage renders independently`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[
                .lanePercent(lane: .primary),
                .lanePercent(lane: .secondary),
                .lanePercent(lane: .tertiary),
                .extraPercent(id: "cursor-grok-bot"),
            ]]),
            data: self.data(
                provider: .cursor,
                extraRateWindows: [MenuBarLayoutRenderExtra(NamedRateWindow(
                    id: "cursor-grok-bot",
                    title: "Grok Bot",
                    window: RateWindow(usedPercent: 42, windowMinutes: nil, resetsAt: nil, resetDescription: nil)))]),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "T 10%\u{2009}C 9%\u{2009}TP 17%\u{2009}GB 42%")
        #expect(output.accessibilityLabel == "Total 10%, Cursor 9%, Third Party 17%, Grok Bot 42%")
    }

    @Test
    func `Cursor semantic tokens follow real resolver windows`() {
        // Cursor's resolver leaves session empty and backs weekly with the secondary (monthly Cursor) lane.
        let renderer = MenuBarLayoutRenderer()
        let data = self.data(provider: .cursor, omitsSession: true, weeklyUsedPercent: 9)
        let expected: [(PercentWindow, String, String)] = [
            (.session, "T –", "Total unavailable"),
            (.weekly, "C 9%", "Cursor 9%"),
        ]
        for (window, value, accessibility) in expected {
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[.percent(window: window)]]),
                data: data,
                icon: nil,
                options: self.options())
            #expect(output.attributedTitle.string == value)
            #expect(output.accessibilityLabel == accessibility)
        }

        let reset = renderer.render(
            layout: MenuBarLayout(lines: [[.windowResetCountdown(window: .weekly)]]),
            data: data,
            icon: nil,
            options: self.options())
        #expect(reset.accessibilityLabel.hasPrefix("Cursor: "))

        let bar = renderer.render(
            layout: MenuBarLayout(lines: [[.progressBar(window: .weekly)]]),
            data: data,
            icon: nil,
            options: self.options())
        #expect(bar.attributedTitle.string.hasPrefix("C "))
        #expect(bar.accessibilityLabel == "Cursor 9%")
    }

    @Test
    func `named extras without short labels keep their full title`() {
        let id = "antigravity-quota-summary-gemini-weekly"
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.extraPercent(id: id)]]),
            data: self.data(
                provider: .antigravity,
                extraRateWindows: [MenuBarLayoutRenderExtra(NamedRateWindow(
                    id: id,
                    title: "Gemini weekly",
                    window: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil)))]),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "Gemini weekly 30%")
        #expect(output.accessibilityLabel == "Gemini weekly 30%")
    }

    @Test
    func `missing Grok Bot extra percentage shows unknown beside sibling tokens`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.lanePercent(lane: .primary), .extraPercent(id: "cursor-grok-bot")]]),
            data: self.data(provider: .cursor),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "T 10%\u{2009}GB –")
        #expect(output.accessibilityLabel == "Total 10%, Grok Bot unavailable")
    }

    @Test
    func `Grok Bot respects remaining mode provider ownership and cache refresh`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.lanePercent(lane: .primary)], [.extraPercent(id: "cursor-grok-bot")]])
        for used in [42.0, 43.0] {
            let extra = MenuBarLayoutRenderExtra(NamedRateWindow(
                id: "cursor-grok-bot",
                title: "Grok Bot",
                window: RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: nil, resetDescription: nil)))
            let output = renderer.render(
                layout: layout,
                data: self.data(provider: .cursor, extraRateWindows: [extra]),
                icon: nil,
                options: self.options(showUsed: false))
            #expect(output.attributedTitle.string == "T 90%\nGB \(Int(100 - used))%")
            let other = renderer.render(
                layout: layout,
                data: self.data(provider: .codex, extraRateWindows: [extra]),
                icon: nil,
                options: self.options())
            #expect(other.attributedTitle.string == "10%")
        }
        let missing = renderer.render(
            layout: layout, data: self.data(provider: .cursor), icon: nil, options: self.options())
        #expect(missing.attributedTitle.string == "T 10%\nGB –")
    }

    @Test(arguments: [0.0, 42.0])
    func `extra unknown readings stay distinct from a real zero`(used: Double) {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.extraPercent(id: "cursor-grok-bot")]])
        for known in [false, true] {
            let extra = MenuBarLayoutRenderExtra(NamedRateWindow(
                id: "cursor-grok-bot",
                title: "Grok Bot",
                window: RateWindow(usedPercent: used, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                usageKnown: known))
            let rendered = renderer.render(
                layout: layout,
                data: self.data(provider: .cursor, extraRateWindows: [extra]),
                icon: nil,
                options: self.options())
            #expect(rendered.attributedTitle.string == (known ? "GB \(Int(used))%" : "GB –"))
            #expect(rendered.accessibilityLabel == (known ? "Grok Bot \(Int(used))%" : "Grok Bot unavailable"))
        }
    }

    @Test
    func `automatic balance text replaces the automatic percent window`() {
        let renderer = MenuBarLayoutRenderer()
        // DeepSeek's funded balance window arrives with usedPercent 0; the balance text must win
        // over the meaningless quota percent.
        let data = self.data(automaticUsedPercent: 0, provider: .deepseek, automaticText: "¥100.00")
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "¥100.00")
        #expect(output.accessibilityLabel == L("%@ %@", L("Usage"), "¥100.00"))
    }

    @Test
    func `duplicate balance cleanup follows visible conditional tokens`() {
        let renderer = MenuBarLayoutRenderer()
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .weeklyResetsIn, comparison: .lessThan, threshold: 48)],
            thenToken: .percent(window: .automatic),
            elseToken: .hidden)
        let layout = MenuBarLayout(lines: [[.conditional(id: conditional.id), .resetCountdown]])
        let data = self.data(automaticText: "¥100.00", automaticBalanceFallback: "¥100.00")
        for now in [self.now, self.now.addingTimeInterval(2 * 24 * 60 * 60)] {
            let result = renderer.render(
                layout: layout,
                data: data,
                icon: nil,
                options: self.options(now: now, conditionals: [conditional]))
            #expect(result.attributedTitle.string == "¥100.00")
        }
    }

    @Test(arguments: [
        [MenuBarLayoutToken.percent(window: .automatic), .resetCountdown, .separatorDot, .costToday],
        [.percent(window: .automatic), .separatorDot, .resetCountdown, .costToday],
        [.percent(window: .automatic), .separatorDot, .resetCountdown, .separatorDot, .costToday],
        [.percent(window: .automatic), .separatorDot, .resetCountdown, .space, .costToday],
        [.percent(window: .automatic), .space, .resetCountdown, .separatorDot, .costToday],
    ])
    func `duplicate reset removal preserves one separator between remaining values`(_ tokens: [MenuBarLayoutToken]) {
        let result = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [tokens]),
            data: self.data(automaticText: "¥100.00", automaticBalanceFallback: "¥100.00"),
            icon: nil,
            options: self.options())
        #expect(result.attributedTitle.string == "¥100.00\u{2009}·\u{2009}$1.25")
    }

    @Test
    func `duplicate reset removal keeps the glyph of a new separator`() {
        let result = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[
                .percent(window: .automatic), .separator(.pipe), .resetCountdown, .separator(.pipe), .costToday,
            ]]),
            data: self.data(automaticText: "¥100.00", automaticBalanceFallback: "¥100.00"),
            icon: nil,
            options: self.options())
        #expect(result.attributedTitle.string == "¥100.00\u{2009}|\u{2009}$1.25")
    }

    @Test
    func `duplicate reset cleanup preserves unrelated edge spaces`() {
        let result = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[
                .space, .percent(window: .automatic), .separatorDot, .resetCountdown,
                .separatorDot, .costToday, .space,
            ]]),
            data: self.data(automaticText: "¥100.00", automaticBalanceFallback: "¥100.00"),
            icon: nil,
            options: self.options())
        #expect(result.attributedTitle.string == " ¥100.00\u{2009}·\u{2009}$1.25 ")
    }

    @Test
    func `automatic text retains a real dated reset`() {
        let result = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic), .separatorDot, .resetCountdown]]),
            data: self.data(automaticText: "¥100.00"),
            icon: nil,
            options: self.options())
        #expect(result.attributedTitle.string.contains("¥100.00"))
        #expect(result.attributedTitle.string.contains("in 2h"))
    }

    @Test
    func `automatic balance text does not override explicit session percent`() {
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
            data: self.data(automaticUsedPercent: 0, provider: .deepseek, automaticText: "¥100.00"),
            icon: nil,
            options: self.options())
        #expect(output.attributedTitle.string == "5h 25%")
    }

    @Test
    func `Amp lane percentages announce snapshot presentation labels`() {
        let renderer = MenuBarLayoutRenderer()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 9, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[
                .lanePercent(lane: .primary),
                .lanePercent(lane: .secondary),
            ]]),
            data: self.data(
                provider: .amp,
                laneLabels: MenuBarLayoutLaneLabels(provider: .amp, snapshot: snapshot)),
            icon: nil,
            options: self.options())

        #expect(output.accessibilityLabel == "Other usage 10%, Orb usage 9%")
    }

    @Test
    func `Notion secondary pace announces monthly cadence`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.pace(window: .weekly)]]),
            data: self.data(provider: .notion),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "+11%")
        #expect(output.accessibilityLabel == L("%@ %@ %@", L("Monthly"), L("display_mode_pace").lowercased(), "+11%"))
    }

    @Test
    func `icon attachment matches the default template size and appearance`() throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
        icon.unlockFocus()
        icon.isTemplate = true

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.icon]]),
            data: self.data(),
            icon: icon,
            options: self.options())

        #expect(output.attributedTitle.string.isEmpty)
        let leadingIcon = try #require(output.leadingIcon)
        #expect(leadingIcon.isTemplate)
        #expect(leadingIcon.size == icon.size)
    }

    @Test
    func `vertical adjustment offsets the surfaced leading icon`() throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        let raised = renderer.render(
            layout: layout,
            data: self.data(),
            icon: icon,
            options: self.options(verticalAdjustment: 2))
        let lowered = renderer.render(
            layout: layout,
            data: self.data(),
            icon: icon,
            options: self.options(verticalAdjustment: -2))

        let raisedIcon = try #require(raised.leadingIcon)
        #expect(raisedIcon.size == NSSize(width: 16, height: 20))
        #expect(raisedIcon.isTemplate)
        let loweredIcon = try #require(lowered.leadingIcon)
        #expect(loweredIcon.size == NSSize(width: 16, height: 20))
        #expect(loweredIcon.isTemplate)
    }

    @Test
    func `vertical adjustment on the surfaced icon is capped to the menu bar height`() throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        icon.isTemplate = true
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: self.options(verticalAdjustment: 10))

        let leadingIcon = try #require(output.leadingIcon)
        #expect(leadingIcon.size == NSSize(width: 18, height: 22))
        #expect(leadingIcon.isTemplate)
    }

    @Test
    func `zero vertical adjustment returns the original leading icon instance`() throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: self.options(verticalAdjustment: 0))

        let leadingIcon = try #require(output.leadingIcon)
        #expect(leadingIcon === icon)
    }

    @Test
    func `missing token data keeps every sibling visible as a placeholder`() {
        let renderer = MenuBarLayoutRenderer()
        let missingData = Self.missingData
        let layout = MenuBarLayout(lines: [[
            .icon,
            .providerName,
            .accountLabel,
            .percent(window: .session),
            .percent(window: .weekly),
            .percent(window: .scopedWeekly),
            .percent(window: .automatic),
            .lanePercent(lane: .primary),
            .lanePercent(lane: .secondary),
            .lanePercent(lane: .tertiary),
            .pace(window: .session),
            .pace(window: .weekly),
            .pace(window: .automatic),
            .usageBar,
            .resetCountdown,
            .resetAbsolute,
            .runsOut,
            .runsOutCompact,
            .balance,
            .costToday,
            .costWindow,
        ]])

        let output = renderer.render(layout: layout, data: missingData, icon: nil, options: self.options())

        #expect(output.attributedTitle.string.count(where: { $0 == "–" }) == 21)
        #expect(output.accessibilityLabel.contains("unavailable"))
    }

    @Test
    func `missing cost window token names the history window in its accessibility text`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.costWindow]])

        #expect(renderer.render(layout: layout, data: Self.missingData, icon: nil, options: self.options())
            .accessibilityLabel == "Cost (History window) unavailable")
    }

    @Test
    func `compact run out token keeps the labeled forecast for accessibility`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.runsOutCompact]]),
            data: self.data(),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "1d 16h")
        #expect(output.accessibilityLabel == "Runs out in 1d 16h")
    }

    @Test
    func `pace token renders the signed delta for its own window`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[
                .percent(window: .weekly),
                .separatorDot,
                .pace(window: .weekly),
            ]]),
            data: self.data(),
            icon: nil,
            options: self.options())

        // Each pace token reads its own window, so weekly pace never borrows the session delta.
        #expect(output.attributedTitle.string == "W 60%\u{2009}·\u{2009}+11%")
        #expect(output.accessibilityLabel.contains(L("menu_bar_layout_token_weekly_pace")))
    }

    @Test
    func `pace token stays a placeholder while siblings keep rendering`() {
        let renderer = MenuBarLayoutRenderer()
        let data = MenuBarLayoutRenderData(
            provider: .codex,
            iconKey: "codex",
            providerName: "Codex",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .codex, snapshot: nil),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            session: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(60 * 60),
                resetDescription: nil)),
            weekly: nil,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: nil,
            automaticText: nil,
            // Pace is suppressed below 3% of window elapsed; the percent token must survive that.
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .session), .separatorDot, .pace(window: .session)]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "5h 25%\u{2009}·\u{2009}–")
        #expect(output.accessibilityLabel.contains("unavailable"))
    }

    @Test
    func `scoped weekly remains percentage only`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[
                .percent(window: .scopedWeekly),
                .separatorDot,
                .pace(window: .scopedWeekly),
            ]]),
            data: self.data(),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "F 80%\u{2009}·\u{2009}–")
        #expect(output.accessibilityLabel.contains("unavailable"))
    }

    @Test
    func `two line title stays within menu bar height`() throws {
        let renderer = MenuBarLayoutRenderer()
        let output = try renderer.render(
            layout: #require(MenuBarLayoutPreset.compactStacked.layout),
            data: self.data(),
            icon: nil,
            options: self.options())
        let bounds = output.attributedTitle.boundingRect(
            with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        #expect(output.attributedTitle.string == "5h 25%\nW 60%")
        #expect(output.accessibilityLabel.contains(L("menu_bar_layout_line", 2)))
        #expect(bounds.height <= 22)
    }

    @Test(arguments: [false, true], [-2, 0, 2])
    func `single provider icon spans two text rows`(explicitSpace: Bool, adjustment: Int) throws {
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let top: [MenuBarLayoutToken] = explicitSpace
            ? [.icon, .space, .percent(window: .session)]
            : [.icon, .percent(window: .session)]
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [top, [.percent(window: .weekly)]]),
            data: self.data(),
            icon: icon,
            options: self.options(verticalAdjustment: adjustment))

        let leadingIcon = try #require(output.leadingIcon)
        #expect(leadingIcon.isTemplate)
        #expect(leadingIcon.size == NSSize(width: 16, height: adjustment == 0 ? 16 : 20))
        if adjustment == 0 {
            #expect(leadingIcon === icon)
        }
        #expect(output.attributedTitle.string == "\(explicitSpace ? " " : "\u{2009}")5h 25%\nW 60%")
        #expect(!output.attributedTitle.string.contains("\u{FFFC}"))
        let expectedAccessibility = "\(L("%@ icon", "Codex")), \(L("Session")) 25%, "
            + "\(L("menu_bar_layout_line", 2)), \(L("Weekly")) 60%"
        #expect(output.accessibilityLabel == expectedAccessibility)
        let bounds = output.attributedTitle.boundingRect(
            with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        #expect(bounds.height <= 22)
        #expect(output.statusImage == nil)
    }

    @Test(arguments: [-2, 2])
    func `shifted two row quota warning icons preserve their red overlay`(adjustment: Int) throws {
        let base = NSImage(size: NSSize(width: 16, height: 16))
        base.isTemplate = true
        let warning = StatusItemController.quotaWarningFlashImage(base: base)
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .session)], [.percent(window: .weekly)]]),
            data: self.data(),
            icon: warning,
            options: self.options(verticalAdjustment: adjustment))

        let leadingIcon = try #require(output.leadingIcon)
        #expect(!leadingIcon.isTemplate)
        let bitmap = try Self.statusBitmap(image: leadingIcon, scale: 1)
        let center = try #require(bitmap.colorAt(x: 8, y: 10))
        #expect(center.alphaComponent > 0)
        #expect(center.redComponent > center.blueComponent)
    }

    @Test(arguments: [
        MenuBarLayout(lines: [[.icon, .percent(window: .session)], [.icon, .percent(window: .weekly)]]),
        MenuBarLayout(lines: [[.icon], [.percent(window: .weekly)]]),
        MenuBarLayout(lines: [[.icon, .space], [.percent(window: .weekly)]]),
        MenuBarLayout(lines: [[.percent(window: .session)], [.icon, .percent(window: .weekly)]]),
        MenuBarLayout(lines: [[.space, .icon, .percent(window: .session)], [.percent(window: .weekly)]]),
    ])
    func `two row icons preserve inline ownership when no single leading mark spans text`(layout: MenuBarLayout) {
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let output = MenuBarLayoutRenderer().render(
            layout: layout, data: self.data(), icon: icon, options: self.options())

        #expect(output.leadingIcon == nil)
        #expect(output.attributedTitle.string.contains("\u{FFFC}"))
    }

    @Test(arguments: ["highContrast", "forceStackedStyle", "colorByProvider", "missingIcon"])
    func `two row leading icons retain rendering overrides`(override: String) {
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .session)], [.percent(window: .weekly)]]),
            data: self.data(),
            icon: override == "missingIcon" ? nil : icon,
            options: self.options(
                colorByProvider: override == "colorByProvider",
                highContrast: override == "highContrast",
                forceStackedStyle: override == "forceStackedStyle"))

        #expect(output.leadingIcon == nil)
        #expect(output.attributedTitle.string.hasPrefix(override == "missingIcon" ? "–" : "\u{FFFC}"))
    }

    @Test
    func `forceStackedStyle applies stacked typography to a single line render`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let stacked = renderer.render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: self.options(forceStackedStyle: true))
        let unstacked = renderer.render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: self.options())

        // Stacked rows render the icon inline in the title (so two rows can carry two different
        // provider icons); the ordinary single-line path surfaces it as the separate leading icon.
        #expect(stacked.leadingIcon == nil)
        #expect(unstacked.leadingIcon != nil)
        #expect(stacked.attributedTitle.string.hasSuffix("50%"))
        #expect(stacked.attributedTitle.string != unstacked.attributedTitle.string)
        #expect(stacked.statusImage?.isTemplate == true)
    }

    @Test(arguments: MenuBarLayoutSize.allCases)
    func `composeStackedProviderRows joins two independently rendered providers into one title`(
        size: MenuBarLayoutSize)
    {
        let renderer = MenuBarLayoutRenderer()
        let topOptions = self.options(size: size, forceStackedStyle: true)
        let top = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: self.data(automaticUsedPercent: 69, provider: .codex),
            icon: nil,
            options: topOptions)
        let bottom = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: self.data(automaticUsedPercent: 45, provider: .claude),
            icon: nil,
            options: topOptions)

        let composed = MenuBarLayoutRenderer.composeStackedProviderRows(
            top: top,
            bottom: bottom,
            topProviderName: "Codex",
            bottomProviderName: "Claude")
        let bounds = composed.attributedTitle.boundingRect(
            with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        #expect(composed.attributedTitle.string == "69%\n45%")
        #expect(composed.accessibilityLabel.contains(L("menu_bar_layout_line", 2)))
        // Neither row's layout includes the icon or provider-name token, so the composed label is the
        // only place a provider is ever named — VoiceOver would otherwise hear two anonymous percentages.
        #expect(composed.accessibilityLabel.contains("Codex"))
        #expect(composed.accessibilityLabel.contains("Claude"))
        #expect(composed.leadingIcon == nil)
        #expect(composed.statusImage?.isTemplate == true)
        #expect(bounds.height <= 22)
    }

    @Test(arguments: ["aqua", "darkAqua"])
    func `stacked bottom updates do not reuse the previous provider rendering`(appearance: String) {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic)]])
        let options = self.options(appearanceName: appearance, forceStackedStyle: true)
        let top = renderer.render(layout: layout, data: self.data(provider: .codex), icon: nil, options: options)
        let before = renderer.render(
            layout: layout, data: self.data(automaticUsedPercent: 10, provider: .claude), icon: nil, options: options)
        let after = renderer.render(
            layout: layout, data: self.data(automaticUsedPercent: 90, provider: .claude), icon: nil, options: options)
        let beforeTitle = MenuBarLayoutRenderer.composeStackedProviderRows(
            top: top, bottom: before, topProviderName: "Codex", bottomProviderName: "Claude")
        let afterTitle = MenuBarLayoutRenderer.composeStackedProviderRows(
            top: top, bottom: after, topProviderName: "Codex", bottomProviderName: "Claude")
        #expect(beforeTitle.attributedTitle.string == "50%\n10%")
        #expect(afterTitle.attributedTitle.string == "50%\n90%")
        #expect(beforeTitle.accessibilityLabel != afterTitle.accessibilityLabel)
    }

    @Test
    func `composeStackedProviderRows drops the separator when one row is emptied by a hidden conditional`() {
        let renderer = MenuBarLayoutRenderer()
        // Session is 25%, so > 50 fails and the else branch (.hidden) wins, emptying the bottom row.
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 50)],
            thenToken: .percent(window: .session),
            elseToken: .hidden)
        let options = self.options(conditionals: [conditional], forceStackedStyle: true)

        let top = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: self.data(automaticUsedPercent: 69, provider: .codex),
            icon: nil,
            options: options)
        let bottom = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: self.data(provider: .claude),
            icon: nil,
            options: options)
        #expect(bottom.attributedTitle.string.isEmpty)

        let composed = MenuBarLayoutRenderer.composeStackedProviderRows(
            top: top,
            bottom: bottom,
            topProviderName: "Codex",
            bottomProviderName: "Claude")

        // No stray blank row or vertical offset — the emptied row is dropped, not stacked as a blank line.
        #expect(composed.attributedTitle.string == "69%")
        #expect(!composed.attributedTitle.string.contains("\n"))
        // The surviving row still gets its provider named, even though only one row made it through.
        #expect(composed.accessibilityLabel == "Codex, \(top.accessibilityLabel)")
    }

    @Test
    func `icon above automatic percentages stays in the attributed two line layout`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let output = renderer.render(
            layout: MenuBarLayout(lines: [
                [.icon],
                [
                    .percent(window: .automatic),
                    .percent(window: .session),
                    .percent(window: .weekly),
                    .lanePercent(lane: .primary),
                ],
            ]),
            data: self.data(),
            icon: icon,
            options: self.options())

        #expect(output.leadingIcon == nil)
        #expect(output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        #expect(output.attributedTitle.string == "\u{FFFC}\n50%\u{2009}5h 25%\u{2009}W 60%\u{2009}10%")
        #expect(output.accessibilityLabel.contains(L("menu_bar_layout_line", 2)))
    }

    @Test
    func `single line icon and automatic percentages keep the surfaced image`() throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[
                .icon,
                .percent(window: .automatic),
                .percent(window: .session),
                .percent(window: .weekly),
            ]]),
            data: self.data(),
            icon: icon,
            options: self.options())

        let leadingIcon = try #require(output.leadingIcon)
        #expect(leadingIcon === icon)
        #expect(output.attributedTitle.string == "\u{2009}50%\u{2009}5h 25%\u{2009}W 60%")
        #expect(output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
    }

    @Test
    func `stacked titles apply a vertical centering offset`() throws {
        let renderer = MenuBarLayoutRenderer()
        let stacked = renderer.render(
            layout: MenuBarLayout(lines: [
                [.percent(window: .automatic)],
                [.resetCountdown],
            ]),
            data: self.data(),
            icon: nil,
            options: self.options())
        let resetIndex = (stacked.attributedTitle.string as NSString).range(of: "in 2h").location
        let singleLine = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic), .resetCountdown]]),
            data: self.data(),
            icon: nil,
            options: self.options())

        #expect(try #require(self.baselineOffset(in: stacked.attributedTitle, at: 0)) == -3)
        #expect(try #require(self.baselineOffset(in: stacked.attributedTitle, at: resetIndex)) == -3)
        #expect(try #require(self.baselineOffset(in: singleLine.attributedTitle, at: 0)) == -1)
    }

    @Test
    func `vertical adjustment shifts single line baseline offset`() throws {
        let renderer = MenuBarLayoutRenderer()
        let base = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: self.data(),
            icon: nil,
            options: self.options())
        let adjusted = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: self.data(),
            icon: nil,
            options: self.options(verticalAdjustment: 2))
        let lifted = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: self.data(),
            icon: nil,
            options: self.options(verticalAdjustment: -2))

        #expect(try #require(self.baselineOffset(in: base.attributedTitle, at: 0)) == -1)
        #expect(try #require(self.baselineOffset(in: adjusted.attributedTitle, at: 0)) == 1)
        #expect(try #require(self.baselineOffset(in: lifted.attributedTitle, at: 0)) == -3)
    }

    @Test(arguments: MenuBarLayoutSize.allCases, [false, true])
    func `layout sizes preserve typography and icon dimensions`(size: MenuBarLayoutSize, stacked: Bool) throws {
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: NSImage(size: NSSize(width: 16, height: 16)),
            options: self.options(size: size, forceStackedStyle: stacked))
        let font = try #require(output.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let paragraph = try #require(output.attributedTitle.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let expectedFontSize: CGFloat = switch size {
        case .small: stacked ? 8 : 11
        case .regular: stacked ? 9 : NSFont.systemFontSize
        case .large: stacked ? 10 : 14
        }
        #expect(font == NSFont.systemFont(ofSize: expectedFontSize, weight: stacked ? .medium : .regular))
        if stacked {
            let attachment = try #require(output.attributedTitle.attribute(
                .attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            #expect(attachment.bounds.height == (size == .small ? 8 : 9))
            #expect(paragraph.minimumLineHeight == (size == .large ? 11 : 9.5))
            #expect(paragraph.maximumLineHeight == paragraph.minimumLineHeight)
            #expect(paragraph.lineSpacing == -1)
        } else {
            #expect(output.leadingIcon?.size.height == 16)
            #expect(paragraph.minimumLineHeight == 0)
            let inline = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
                data: self.data(),
                icon: NSImage(size: NSSize(width: 16, height: 16)),
                options: self.options(size: size, highContrast: true))
            let attachment = try #require(inline.attributedTitle.attribute(
                .attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            #expect(attachment.bounds.height == (size == .small ? 14 : 18))
        }
    }

    @Test(arguments: MenuBarLayoutSize.allCases, [false, true])
    func `monospaced digits use equal advances and invalidate the cached font`(
        size: MenuBarLayoutSize, stacked: Bool) throws
    {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic)]])
        let data = self.data()
        let standard = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(size: size, forceStackedStyle: stacked))
        let monospaced = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(size: size, forceStackedStyle: stacked, monospacedDigits: true))
        let font = try #require(monospaced.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let originalFont = try #require(standard.attributedTitle.attribute(
            .font,
            at: 0,
            effectiveRange: nil) as? NSFont)
        #expect(font == NSFont.monospacedDigitSystemFont(
            ofSize: originalFont.pointSize, weight: stacked ? .medium : .regular))
        #expect(monospaced.attributedTitle !== standard.attributedTitle)
        let digitWidths = (0...9).map { digit in
            NSAttributedString(string: String(digit), attributes: [.font: font]).size().width
        }
        #expect(try #require(digitWidths.max()) - #require(digitWidths.min()) < 0.01)
        #expect(monospaced.attributedTitle.string == standard.attributedTitle.string)
        let restored = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(size: size, forceStackedStyle: stacked))
        #expect(restored.attributedTitle === standard.attributedTitle)
    }

    @Test
    func `two line text uses medium weight and reuses its cached title`() throws {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .session)], [.percent(window: .weekly)]])
        let data = self.data()
        let options = self.options()
        let output = renderer.render(layout: layout, data: data, icon: nil, options: options)
        let title = output.attributedTitle
        for index in [0, title.length - 1] {
            let font = try #require(title.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            #expect(font == NSFont.systemFont(ofSize: 9, weight: .medium))
        }
        #expect(renderer.render(layout: layout, data: data, icon: nil, options: options).attributedTitle === title)
    }

    @Test(arguments: MenuBarLayoutSize.allCases)
    func `two line icon uses compact paragraph metrics`(size: MenuBarLayoutSize) {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let output = renderer.render(
            layout: MenuBarLayout(lines: [
                [.icon, .percent(window: .session)],
                [.percent(window: .weekly)],
            ]),
            data: self.data(),
            icon: icon,
            options: self.options(size: size))
        let bounds = output.attributedTitle.boundingRect(
            with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        #expect(output.attributedTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) is NSParagraphStyle)
        #expect(bounds.height <= 22)
    }

    @Test(arguments: [false, true])
    func `large inline icons fit both stacked rows without changing text typography`(monospacedDigits: Bool) throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        for options in [
            self.options(size: .large, monospacedDigits: monospacedDigits),
            self.options(size: .large, highContrast: true, monospacedDigits: monospacedDigits),
            self.options(size: .large, colorByProvider: true, monospacedDigits: monospacedDigits),
            self.options(size: .large, forceStackedStyle: true, monospacedDigits: monospacedDigits),
        ] {
            let output = renderer.render(
                layout: MenuBarLayout(lines: [
                    [.icon, .percent(window: .session)],
                    [.icon, .percent(window: .weekly)],
                ]),
                data: self.data(),
                icon: icon,
                options: options)
            let bounds = output.attributedTitle.boundingRect(
                with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            let font = try #require(output.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.pointSize == 10)
            #expect(bounds.height <= 22)
            #expect(try #require(self.baselineOffset(in: output.attributedTitle, at: 0)) == -1)

            if options.forceStackedStyle {
                let row = renderer.render(
                    layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
                    data: self.data(),
                    icon: icon,
                    options: options)
                let composed = MenuBarLayoutRenderer.composeStackedProviderRows(
                    top: row, bottom: row, topProviderName: "Codex", bottomProviderName: "Claude")
                let composedBounds = composed.attributedTitle.boundingRect(
                    with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                #expect(composedBounds.height <= 22)
            }

            let missingIcon = renderer.render(
                layout: MenuBarLayout(lines: [[.icon, .percent(window: .session)], [.percent(window: .weekly)]]),
                data: self.data(),
                icon: nil,
                options: options)
            #expect(try #require(self.baselineOffset(in: missingIcon.attributedTitle, at: 0)) == -3)
        }
    }

    @Test
    func `cached path renders one thousand titles under budget`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic), .separatorDot, .resetCountdown]])
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        // Fixture construction is not part of the renderer's cached path.
        let data = self.data()
        let options = self.options()
        let first = renderer.render(layout: layout, data: data, icon: icon, options: options)
        var last = first
        var fastest = Duration.seconds(10)

        // Thread CPU time keeps the frozen 50 ms budget on rendering work; wall-clock time failed on
        // preempted CI runners. Best-of-three still absorbs one-off cache misses.
        for _ in 0..<3 {
            let startedAt = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            for _ in 0..<1000 {
                last = renderer.render(layout: layout, data: data, icon: icon, options: options)
            }
            let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - startedAt
            fastest = min(fastest, .nanoseconds(Int64(elapsed)))
        }

        #expect(first.attributedTitle === last.attributedTitle)
        #expect(fastest < .milliseconds(50), "Fastest cached batch used \(fastest) of thread CPU time")
    }

    @Test
    func `cached renders skip icon layout for equivalent rebuilt inputs`() {
        let cache = MenuBarLayoutTitleCache()
        let renderer = MenuBarLayoutRenderer(cache: cache)
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic), .separatorDot, .resetCountdown]])
        let icon = MenuBarLayoutSizeCountingImage(size: NSSize(width: 16, height: 16))
        let first = renderer.render(layout: layout, data: self.data(), icon: icon, options: self.options())
        let initialSizeReads = icon.sizeReadCount
        #expect(initialSizeReads > 0)

        // Uncached rendering reads the icon size even when it returns the original image.
        for _ in 0..<1000 {
            let cached = renderer.render(layout: layout, data: self.data(), icon: icon, options: self.options())
            #expect(cached.attributedTitle === first.attributedTitle)
            #expect(cached.leadingIcon === icon)
        }
        #expect(icon.sizeReadCount == initialSizeReads)
        #expect(cache.count == 1)

        let changed = renderer.render(
            layout: layout,
            data: self.data(automaticUsedPercent: 75),
            icon: icon,
            options: self.options())
        #expect(changed.attributedTitle !== first.attributedTitle)
        #expect(changed.attributedTitle.string.contains("75%"))
        #expect(icon.sizeReadCount > initialSizeReads)
        #expect(cache.count == 2)

        let sizeReadsBeforeClear = icon.sizeReadCount
        renderer.removeAll()
        // The cache has no isEmpty property.
        // swiftlint:disable:next empty_count
        #expect(cache.count == 0)
        let rebuilt = renderer.render(layout: layout, data: self.data(), icon: icon, options: self.options())
        #expect(rebuilt.attributedTitle !== first.attributedTitle)
        #expect(rebuilt.attributedTitle.string == first.attributedTitle.string)
        #expect(icon.sizeReadCount > sizeReadsBeforeClear)
        #expect(cache.count == 1)
    }

    @Test(arguments: [MenuBarLayoutToken.resetAbsolute, .percent(window: .automatic)])
    func `unreferenced reset text does not invalidate cached titles`(token: MenuBarLayoutToken) {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[token]])
        let data = self.data()
        let first = renderer.render(layout: layout, data: data, icon: nil, options: self.options())
        let later = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: self.now.addingTimeInterval(60)))

        #expect(first.attributedTitle.string == later.attributedTitle.string)
        #expect(
            first.attributedTitle === later.attributedTitle,
            "An unreferenced countdown must not invalidate the title")
    }

    @Test
    func `countdown uses the exact clock while caching an unchanged displayed minute`() {
        let renderer = MenuBarLayoutRenderer()
        let minuteStart = self.now
        let now = minuteStart.addingTimeInterval(51)
        let resetAt = minuteStart.addingTimeInterval(6 * 60 + 50)
        let data = self.data(automaticResetAt: resetAt)
        let layout = MenuBarLayout(lines: [[.resetCountdown]])

        // Rounding the clock back to the wall-minute boundary reproduces the reported one-minute mismatch.
        #expect(UsageFormatter.resetCountdownDescription(from: resetAt, now: minuteStart) == "in 7m")
        let first = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: now))
        #expect(first.attributedTitle.string == "in 6m")

        // A different exact instant with the same visible value still hits the attributed-title cache.
        let sameMinute = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: now.addingTimeInterval(20)))
        #expect(first.attributedTitle === sameMinute.attributedTitle)

        let nextMinute = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: now.addingTimeInterval(60)))
        #expect(nextMinute.attributedTitle.string == "in 5m")
        #expect(first.attributedTitle !== nextMinute.attributedTitle)
    }

    @Test
    func `usage bar follows remaining display direction`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.usageBar]]),
            data: self.data(automaticUsedPercent: 10),
            icon: nil,
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: false,
                conditionals: [],
                appearanceName: "aqua",
                isDebugApp: false,
                now: self.now))

        #expect(output.attributedTitle.string == "▮▮▮")
    }

    @Test(arguments: [PercentWindow.session, .weekly, .scopedWeekly, .automatic])
    func `progress bar renders a graphical attachment with a window label`(window: PercentWindow) throws {
        let renderer = MenuBarLayoutRenderer()
        let token = MenuBarLayoutToken.progressBar(window: window)
        #expect(MenuBarLayoutPaletteTokens.usage(provider: .codex, snapshot: nil).contains(token))
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[token]]),
            data: self.data(),
            icon: nil,
            options: self.options(showUsed: true))

        // Attachment payloads appear as U+FFFC in `string`; the visible bar is an image attachment.
        let text = output.attributedTitle.string
        #expect(text.contains("\u{FFFC}"))
        #expect(output.attributedTitle.length >= 1)
        let attachmentIndex = try #require(text.firstIndex(of: "\u{FFFC}"))
        let attachment = output.attributedTitle.attribute(
            .attachment,
            at: text.distance(from: text.startIndex, to: attachmentIndex),
            effectiveRange: nil) as? NSTextAttachment
        #expect(attachment?.image != nil)

        switch window {
        case .session:
            #expect(text.hasPrefix("5h "))
            #expect(output.accessibilityLabel.contains("25%"))
        case .weekly:
            #expect(text.hasPrefix("W "))
            #expect(output.accessibilityLabel.contains("60%"))
        case .automatic:
            #expect(text == "\u{FFFC}")
            #expect(output.accessibilityLabel.contains("50%"))
        case .scopedWeekly:
            #expect(text.hasPrefix("F "))
            #expect(output.accessibilityLabel.contains("80%"))
        case .spend:
            Issue.record("Spend has no progress bar palette token")
        }
    }

    @Test
    func `progress bar placeholder appears when its window is missing`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.progressBar(window: .session)]]),
            data: Self.missingData,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "–")
        #expect(output.accessibilityLabel.contains("unavailable"))
    }

    @Test
    func `progress bar keeps balance text instead of drawing an automatic bar`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.progressBar(window: .automatic)]]),
            data: self.data(automaticUsedPercent: 80, provider: .deepseek, automaticText: "¥100.00"),
            icon: nil,
            options: self.options(showUsed: true))

        #expect(output.attributedTitle.string == "¥100.00")
        #expect(!output.attributedTitle.string.contains("\u{FFFC}"))
    }

    @Test
    func `progress bar degrades to percent in older layout projections`() {
        let token = MenuBarLayoutToken.progressBar(window: .session)
        #expect(!token.hasReleasedRepresentation)
        #expect(!token.hasV3Representation)
        #expect(!token.hasLegacyRepresentation)
        #expect(MenuBarLayout(lines: [[.icon, token, .resetCountdown]]).legacyCompatible()
            == MenuBarLayout(lines: [[.icon, .percent(window: .session), .resetCountdown]]))
        #expect(MenuBarLayout(lines: [[.icon, token]]).releasedCompatible()
            == MenuBarLayout(lines: [[.icon, .percent(window: .session)]]))
    }

    @Test
    func `absolute reset falls back to provider text`() {
        let renderer = MenuBarLayoutRenderer()
        let textOnlyWindow = MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: 20,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "Friday at 10:00"))
        let data = MenuBarLayoutRenderData(
            provider: .codex,
            iconKey: "codex",
            providerName: "Codex",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .codex, snapshot: nil),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            session: nil,
            weekly: nil,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: textOnlyWindow,
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.resetAbsolute]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "Friday at 10:00")
    }

    @Test
    func `high contrast title keeps icon and text in one attributed path`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        var options = self.options()
        options = MenuBarLayoutRenderOptions(
            size: options.size,
            highContrast: true,
            showUsed: options.showUsed,
            conditionals: options.conditionals,
            appearanceName: options.appearanceName,
            isDebugApp: options.isDebugApp,
            now: options.now)
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: options)

        // High contrast keeps the icon inside the attributed title (not surfaced as button.image)
        // so AppKit dims the whole title together on inactive displays.
        #expect(output.leadingIcon == nil)
        #expect(output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        let textIndex = (output.attributedTitle.string as NSString).range(of: "50%").location
        #expect(output.attributedTitle
            .attribute(.foregroundColor, at: textIndex, effectiveRange: nil) as? NSColor == .labelColor)
    }

    @Test
    func `extracted leading icon keeps its accessibility description`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: self.options())

        #expect(output.leadingIcon != nil)
        #expect(output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
        #expect(output.accessibilityLabel.contains(L("%@ icon", "Codex")))
    }

    @Test
    func `stale title dims foreground while keeping the snapshot visible`() {
        let renderer = MenuBarLayoutRenderer()
        let fresh = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: self.data(),
            icon: nil,
            options: self.options())
        let stale = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]),
            data: self.data(),
            icon: nil,
            options: self.options(isStale: true))

        #expect(stale.attributedTitle.string == fresh.attributedTitle.string)
        #expect(stale.attributedTitle
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(fresh.attributedTitle
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .controlTextColor)
    }

    @Test(arguments: [
        (0.0, MenuBarLayoutToken.percent(window: .session), "5h 25%"),
        (50.0, MenuBarLayoutToken.resetCountdown, "in 2h"),
    ])
    func `conditional renders the matching branch`(threshold: Double, token: MenuBarLayoutToken, expected: String) {
        let renderer = MenuBarLayoutRenderer()
        // Session is 25%, so the two thresholds exercise both branches.
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: threshold)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let data = self.data()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: data,
            icon: nil,
            options: self.options(conditionals: [conditional]))
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[token]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == control.attributedTitle.string)
        #expect(output.attributedTitle.string == expected)
    }

    @Test
    func `conditional and requires all predicates`() {
        let renderer = MenuBarLayoutRenderer()
        let data = self.data()

        // Session 25% > 0 (true) AND weekly 60% > 70 (false) -> whole clause false.
        let falseConditional = MenuBarLayoutConditional(
            clauses: [
                self.clause(metric: .session, comparison: .greaterThan, threshold: 0),
                self.clause(metric: .weekly, comparison: .greaterThan, threshold: 70, combinator: .and),
            ],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let falseOutput = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: falseConditional.id)]]),
            data: data,
            icon: nil,
            options: self.options(conditionals: [falseConditional]))
        let falseControl = renderer.render(
            layout: MenuBarLayout(lines: [[.resetCountdown]]),
            data: data,
            icon: nil,
            options: self.options())
        #expect(falseOutput.attributedTitle.string == falseControl.attributedTitle.string)

        // Session 25% > 0 (true) AND weekly 60% > 50 (true) -> all predicates pass.
        let trueConditional = MenuBarLayoutConditional(
            clauses: [
                self.clause(metric: .session, comparison: .greaterThan, threshold: 0),
                self.clause(metric: .weekly, comparison: .greaterThan, threshold: 50, combinator: .and),
            ],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let trueOutput = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: trueConditional.id)]]),
            data: data,
            icon: nil,
            options: self.options(conditionals: [trueConditional]))
        let trueControl = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
            data: data,
            icon: nil,
            options: self.options())
        #expect(trueOutput.attributedTitle.string == trueControl.attributedTitle.string)
        #expect(trueOutput.attributedTitle.string == "5h 25%")
    }

    @Test
    func `conditional or accepts any predicate`() {
        let renderer = MenuBarLayoutRenderer()
        // Weekly 60% > 70 (false) OR session 25% > 0 (true) -> whole clause true.
        let conditional = MenuBarLayoutConditional(
            clauses: [
                self.clause(metric: .weekly, comparison: .greaterThan, threshold: 70),
                self.clause(metric: .session, comparison: .greaterThan, threshold: 0, combinator: .or),
            ],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let data = self.data()

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: data,
            icon: nil,
            options: self.options(conditionals: [conditional]))
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == control.attributedTitle.string)
        #expect(output.attributedTitle.string == "5h 25%")
    }

    @Test
    func `conditional with missing metric window falls to else`() {
        let renderer = MenuBarLayoutRenderer()
        // Session window is nil, so the session predicate evaluates false (not "0 > 0").
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 0)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let data = Self.missingData

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: data,
            icon: nil,
            options: self.options(conditionals: [conditional]))
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.resetCountdown]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == control.attributedTitle.string)
        #expect(output.attributedTitle.string == "–")
    }

    @Test
    func `nested conditional depth cap renders placeholder`() {
        let renderer = MenuBarLayoutRenderer()
        // A conditionals entry may reference itself through its branches; the renderer caps
        // traversal at maxConditionalDepth.
        let selfID = UUID()
        let looping = MenuBarLayoutConditional(
            id: selfID,
            name: "loop",
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 0)],
            thenToken: .conditional(id: selfID),
            elseToken: .space)
        let data = self.data()
        // The cap triggers before any branch is evaluated, independent of live values,
        // so the missing-value placeholder is the expected title.
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: selfID)]]),
            data: data,
            icon: nil,
            options: self.options(conditionals: [looping]))

        #expect(output.attributedTitle.string == "–")
    }

    @Test
    func `conditional accessibility announces the chosen branch`() {
        let renderer = MenuBarLayoutRenderer()
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 0)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let data = self.data()

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: data,
            icon: nil,
            options: self.options(conditionals: [conditional]))
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.accessibilityLabel == control.accessibilityLabel)
        #expect(output.accessibilityLabel == L("%@ %@", L("Session"), "25%"))
    }

    @Test
    func `hidden branch leaves no orphaned spacing`() {
        let renderer = MenuBarLayoutRenderer()
        // Session is 25%, so a > 50 threshold fails and the else branch (.hidden) wins: the
        // conditional contributes nothing, and the neighbors must join without a stray separator.
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 50)],
            thenToken: .percent(window: .session),
            elseToken: .hidden)
        let options = self.options(conditionals: [conditional])

        let middle = renderer.render(
            layout: MenuBarLayout(lines: [[
                .percent(window: .session),
                .conditional(id: conditional.id),
                .percent(window: .weekly),
            ]]),
            data: self.data(),
            icon: nil,
            options: options)
        #expect(middle.attributedTitle.string == "5h 25%\u{2009}W 60%")

        let trailing = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .session), .conditional(id: conditional.id)]]),
            data: self.data(),
            icon: nil,
            options: options)
        #expect(trailing.attributedTitle.string == "5h 25%")
    }

    @Test
    func `a line emptied by a hidden branch collapses instead of rendering blank`() throws {
        let renderer = MenuBarLayoutRenderer()
        // Session is 25%, so > 50 fails and the else branch (.hidden) wins on the conditional line.
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 50)],
            thenToken: .percent(window: .session),
            elseToken: .hidden)
        let options = self.options(conditionals: [conditional])

        // Leading line hidden: no leading newline, and no empty VoiceOver line.
        let leadingHidden = renderer.render(
            layout: MenuBarLayout(lines: [
                [.conditional(id: conditional.id)],
                [.percent(window: .weekly)],
            ]),
            data: self.data(),
            icon: nil,
            options: options)
        #expect(leadingHidden.attributedTitle.string == "W 60%")
        #expect(!leadingHidden.accessibilityLabel.contains(L("menu_bar_layout_line", 2)))

        // Trailing line hidden: no trailing newline.
        let trailingHidden = renderer.render(
            layout: MenuBarLayout(lines: [
                [.percent(window: .weekly)],
                [.conditional(id: conditional.id)],
            ]),
            data: self.data(),
            icon: nil,
            options: options)
        #expect(trailingHidden.attributedTitle.string == "W 60%")

        // A collapsed layout also drops stacked typography: it matches the single-line control.
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .weekly)]]),
            data: self.data(),
            icon: nil,
            options: options)
        let collapsedOffset = try #require(self.baselineOffset(in: leadingHidden.attributedTitle, at: 0))
        let controlOffset = try #require(self.baselineOffset(in: control.attributedTitle, at: 0))
        #expect(collapsedOffset == controlOffset)
        #expect(leadingHidden.attributedTitle.isEqual(to: control.attributedTitle))
        #expect(leadingHidden.accessibilityLabel == control.accessibilityLabel)
    }

    @Test
    func `every line hidden renders an empty title without crashing`() {
        let renderer = MenuBarLayoutRenderer()
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 50)],
            thenToken: .percent(window: .session),
            elseToken: .hidden)

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [conditional]))
        #expect(output.attributedTitle.string.isEmpty)
        #expect(output.accessibilityLabel.isEmpty)

        // The debug marker has no line to attach to once everything collapsed.
        let debug = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [conditional], isDebugApp: true))
        #expect(debug.attributedTitle.string == " D")
        #expect(debug.accessibilityLabel == L("Debug"))
    }

    @Test
    func `a conditional resolving to the icon surfaces it as the leading image`() throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        // Session is 25%, so > 0 passes and the then branch (.icon) wins in first position.
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 0)],
            thenToken: .icon,
            elseToken: .hidden)

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id), .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: self.options(conditionals: [conditional]))
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: self.options())

        // AppKit only dims `button.image` on inactive displays, so a resolved icon has to take the
        // same path a literal `.icon` token takes rather than becoming an attributed attachment.
        let resolvedIcon = try #require(output.leadingIcon)
        let controlIcon = try #require(control.leadingIcon)
        #expect(resolvedIcon === controlIcon)
        #expect(output.attributedTitle.string == control.attributedTitle.string)
        #expect(output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
        #expect(output.accessibilityLabel == control.accessibilityLabel)
    }

    @Test
    func `dangling conditional reference renders placeholder`() {
        let renderer = MenuBarLayoutRenderer()
        // An id not present in the library has nothing to resolve; the renderer must show the
        // missing-value placeholder instead of emitting a branch.
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: UUID())]]),
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: []))

        #expect(output.attributedTitle.string == "–")
        #expect(output.accessibilityLabel.contains(L("menu_bar_layout_conditional_unavailable")))
    }

    @Test
    func `library edit changes the rendered branch without touching the layout`() {
        let renderer = MenuBarLayoutRenderer()
        let id = UUID()
        // The layout only stores the reference; the library entry decides the branch.
        let layout = MenuBarLayout(lines: [[.conditional(id: id)]])

        let conditionTrue = MenuBarLayoutConditional(
            id: id,
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 0)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let first = renderer.render(
            layout: layout,
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [conditionTrue]))
        #expect(first.attributedTitle.string == "5h 25%")

        // Flip the comparison so the same layout now renders the else branch.
        let conditionFalse = MenuBarLayoutConditional(
            id: id,
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 50)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let second = renderer.render(
            layout: layout,
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [conditionFalse]))
        #expect(second.attributedTitle.string != first.attributedTitle.string)
        #expect(second.attributedTitle.string == "in 2h")
    }

    @Test
    func `mixed and or evaluates as a left fold`() {
        let renderer = MenuBarLayoutRenderer()
        // Session 25% > 0 (T) or weekly 60% > 90 (F) and automatic 50% > 90 (F).
        // The left fold yields ((T ∨ F) ∧ F) = false, so the else branch wins; conventional
        // precedence (T ∨ (F ∧ F) = true) would pick the then branch instead.
        let conditional = MenuBarLayoutConditional(
            clauses: [
                self.clause(metric: .session, comparison: .greaterThan, threshold: 0),
                self.clause(metric: .weekly, comparison: .greaterThan, threshold: 90, combinator: .or),
                self.clause(metric: .automatic, comparison: .greaterThan, threshold: 90, combinator: .and),
            ],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [conditional]))
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.resetCountdown]]),
            data: self.data(),
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == control.attributedTitle.string)
        #expect(output.attributedTitle.string == "in 2h")
    }

    /// The fixture's session resets one hour out, so a `< 2h` countdown predicate holds. Rewinding the
    /// clock four hours puts the reset five hours out and the same predicate must stop holding.
    @Test
    func `resets-in predicate picks the then branch inside the threshold`() {
        let renderer = MenuBarLayoutRenderer()
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .sessionResetsIn, comparison: .lessThan, threshold: 2)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let layout = MenuBarLayout(lines: [[.conditional(id: conditional.id)]])

        let inside = renderer.render(
            layout: layout,
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [conditional]))
        #expect(inside.attributedTitle.string == "5h 25%")

        let outside = renderer.render(
            layout: layout,
            data: self.data(),
            icon: nil,
            options: self.options(
                now: self.now.addingTimeInterval(-4 * 60 * 60),
                conditionals: [conditional]))
        #expect(outside.attributedTitle.string == "in 6h")
    }

    @Test
    func `session percent and resets-in combine with and`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = { (conditional: MenuBarLayoutConditional) in
            MenuBarLayout(lines: [[.conditional(id: conditional.id)]])
        }
        let passing = MenuBarLayoutConditional(
            clauses: [
                self.clause(metric: .session, comparison: .greaterThan, threshold: 20),
                self.clause(
                    metric: .sessionResetsIn,
                    comparison: .lessThan,
                    threshold: 2,
                    combinator: .and),
            ],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let failing = MenuBarLayoutConditional(
            clauses: [
                self.clause(metric: .session, comparison: .greaterThan, threshold: 90),
                self.clause(
                    metric: .sessionResetsIn,
                    comparison: .lessThan,
                    threshold: 2,
                    combinator: .and),
            ],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)

        let then = renderer.render(
            layout: layout(passing),
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [passing]))
        #expect(then.attributedTitle.string == "5h 25%")

        let otherwise = renderer.render(
            layout: layout(failing),
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [failing]))
        #expect(otherwise.attributedTitle.string == "in 2h")
    }

    /// Session is 25% used, so 75% remains: the same threshold must flip with the direction.
    @Test
    func `remaining direction inverts the percent reading`() {
        #expect(self.branchText(self.clause(
            metric: .session,
            comparison: .greaterThan,
            threshold: 50,
            direction: .remaining)) == "5h 25%")
        #expect(self.branchText(self.clause(
            metric: .session,
            comparison: .greaterThan,
            threshold: 50,
            direction: .used)) == "in 2h")
    }

    @Test
    func `balance direction selects used or remaining amount`() {
        #expect(self.branchText(self.clause(
            metric: .balance,
            comparison: .greaterThan,
            threshold: 10,
            direction: .remaining)) == "5h 25%")
        #expect(self.branchText(self.clause(
            metric: .balance,
            comparison: .greaterThan,
            threshold: 10,
            direction: .used)) == "in 2h")
    }

    @Test
    func `pace run-out and cost predicates read numeric metrics`() {
        #expect(self.branchText(self.clause(
            metric: .weeklyPace,
            comparison: .greaterThan,
            threshold: 10)) == "5h 25%")
        // 2400 minutes == 40 hours.
        #expect(self.branchText(self.clause(
            metric: .runsOutIn,
            comparison: .lessThan,
            threshold: 48)) == "5h 25%")
        #expect(self.branchText(self.clause(
            metric: .runsOutIn,
            comparison: .lessThan,
            threshold: 12)) == "in 2h")
        #expect(self.branchText(self.clause(
            metric: .costToday,
            comparison: .greaterThanOrEqual,
            threshold: 1)) == "5h 25%")
        #expect(self.branchText(self.clause(
            metric: .tertiaryLane,
            comparison: .greaterThan,
            threshold: 10)) == "5h 25%")
    }

    @Test
    func `predicate on a metric with no datum evaluates false`() {
        let renderer = MenuBarLayoutRenderer()
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .costWindow, comparison: .greaterThanOrEqual, threshold: 0)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: self.data(metrics: .unavailable),
            icon: nil,
            options: self.options(conditionals: [conditional]))
        #expect(output.attributedTitle.string == "in 2h")
    }

    /// Regression guard for the title cache: a countdown predicate flips with nothing but the clock, and
    /// the automatic window's reset text — the only time-derived key component before this — does not
    /// distinguish the two renders here.
    @Test
    func `time based conditional flips when only the clock advances`() {
        let renderer = MenuBarLayoutRenderer()
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .weeklyResetsIn, comparison: .lessThan, threshold: 48)],
            thenToken: .percent(window: .session),
            elseToken: .hidden)
        let layout = MenuBarLayout(lines: [[.conditional(id: conditional.id)]])
        let data = self.data()

        // Weekly resets 3 days out: 72h > 48h, so the else branch hides the token.
        let before = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(conditionals: [conditional]))
        #expect(before.attributedTitle.string.isEmpty)

        // Two days later the same weekly reset is 24h out and the then branch must win.
        let after = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(
                now: self.now.addingTimeInterval(2 * 24 * 60 * 60),
                conditionals: [conditional]))
        #expect(after.attributedTitle.string == "5h 25%")
    }

    /// Renders a single-clause conditional whose then branch is the session percent and whose else
    /// branch is the automatic reset countdown, so a caller can assert which branch won by text.
    private func branchText(_ clause: MenuBarConditionalClause, data: MenuBarLayoutRenderData? = nil) -> String {
        let conditional = MenuBarLayoutConditional(
            clauses: [clause],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        return MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.conditional(id: conditional.id)]]),
            data: data ?? self.data(),
            icon: nil,
            options: self.options(conditionals: [conditional])).attributedTitle.string
    }

    /// End-to-end proof for the shipped "Auto % / Resets in" default: while the automatic lane still has
    /// headroom it renders the percentage, and once the quota is spent it swaps to the reset countdown.
    @Test
    func `shipped auto default swaps percent for the countdown once the quota is spent`() {
        let renderer = MenuBarLayoutRenderer()
        let shipped = MenuBarLayoutConditional.shippedLibrary()
        guard let auto = shipped.first(where: { entry in
            entry.clauses.contains { $0.predicate.direction == .remaining }
        }) else {
            Issue.record("expected a shipped automatic remaining-direction conditional")
            return
        }
        #expect(auto.displayName == "Auto % / Resets in")
        let layout = MenuBarLayout(lines: [[.conditional(id: auto.id)]])

        let withHeadroom = renderer.render(
            layout: layout,
            data: self.data(),
            icon: nil,
            options: self.options(conditionals: [auto]))
        #expect(withHeadroom.attributedTitle.string == "50%")

        let spent = renderer.render(
            layout: layout,
            data: self.data(automaticUsedPercent: 100),
            icon: nil,
            options: self.options(conditionals: [auto]))
        #expect(spent.attributedTitle.string == "in 2h")
    }

    @Test
    func `shipped spend conditional shows spend percent at ninety percent used`() throws {
        let spend = try #require(MenuBarLayoutConditional.shippedLibrary().first {
            $0.thenToken == .percent(window: .spend)
        })
        #expect(spend.displayName == "Spend over 90% used")

        let render = { (usedPercent: Double) -> String in
            var data = self.data()
            data.spend = MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil))
            return MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[.conditional(id: spend.id)]]),
                data: data,
                icon: nil,
                options: self.options(conditionals: [spend])).attributedTitle.string
        }
        #expect(render(89).isEmpty)
        #expect(render(90) == "$ 90%")
    }

    private func clause(
        metric: MenuBarConditionalMetric,
        comparison: MenuBarConditionalComparison,
        threshold: Double,
        direction: MenuBarConditionalDirection = .used,
        combinator: MenuBarConditionalCombinator? = nil) -> MenuBarConditionalClause
    {
        MenuBarConditionalClause(
            combinator: combinator,
            predicate: MenuBarConditionalPredicate(
                metric: metric,
                direction: direction,
                comparison: comparison,
                threshold: threshold))
    }

    @Test
    func `pace state bars keep signed text neutral and scale with the font`() throws {
        for size in MenuBarLayoutSize.allCases {
            let rendered = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[.pace(window: .weekly)]]),
                data: self.data(),
                icon: nil,
                options: self.options(size: size, colorPace: true))
            let title = rendered.attributedTitle
            let attachment = try #require(title.attribute(.attachment, at: 0, effectiveRange: nil)
                as? NSTextAttachment)
            let font = try #require(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(attachment.bounds.height == font.capHeight)
            #expect(attachment.bounds.width == font.capHeight / 2)
            #expect(title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor
                == .controlTextColor)
            #expect(rendered.accessibilityLabel.contains("+11%"))
        }
    }

    @Test
    func `pace colors follow reserve and ahead values and toggle invalidates cache`() {
        let renderer = MenuBarLayoutRenderer()
        let cases: [(PercentWindow, NSColor)] = [
            (.session, .systemGreen), (.weekly, .systemRed), (.automatic, .controlTextColor),
            (.spend, .systemRed),
        ]
        for (window, expectedColor) in cases {
            let layout = MenuBarLayout(lines: [[.pace(window: window)]])
            let plain = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options())
            let colored = renderer.render(
                layout: layout, data: self.data(), icon: nil, options: self.options(colorPace: true))
            #expect(plain.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == .controlTextColor)
            #expect(colored.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == expectedColor)
            #expect(colored.accessibilityLabel == plain.accessibilityLabel)
            #expect(plain.statusImage?.isTemplate == true)
            #expect((colored.statusImage == nil) == (window != .automatic))
            let button = NSButton()
            for output in [plain, colored] {
                _ = StatusItemController.applyMenuBarLayoutContent(output, for: button, gap: .regular)
            }
            if window != .automatic {
                #expect(button.image == nil)
                #expect(button.attributedTitle.isEqual(to: colored.attributedTitle))
            }
            #expect(button.accessibilityTitle() == colored.accessibilityLabel)
            let restored = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options())
            #expect(restored.attributedTitle.isEqual(to: plain.attributedTitle))
            _ = StatusItemController.applyMenuBarLayoutContent(restored, for: button, gap: .regular)
            #expect(button.image?.isTemplate == true)
            #expect(button.attributedTitle.length == 0)
        }
    }

    @Test
    func `pace color leaves other tokens and missing metrics neutral`() {
        let renderer = MenuBarLayoutRenderer()
        for token: MenuBarLayoutToken in [.percent(window: .session), .providerName, .pace(window: .scopedWeekly)] {
            let rendered = renderer.render(
                layout: MenuBarLayout(lines: [[token]]),
                data: self.data(),
                icon: nil,
                options: self.options(colorPace: true))
            #expect(rendered.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == .controlTextColor)
            #expect(rendered.statusImage?.isTemplate == true)
        }
        let missing = renderer.render(
            layout: MenuBarLayout(lines: [[.pace(window: .session)]]),
            data: self.data(metrics: .unavailable),
            icon: nil,
            options: self.options(colorPace: true))
        #expect(missing.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == .controlTextColor)
        #expect(missing.statusImage?.isTemplate == true)
    }

    @Test(arguments: [MenuBarLayoutToken.hidden, .percent(window: .automatic)])
    func `resolved conditionals choose native colors only for visible pace`(fallback: MenuBarLayoutToken) {
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .automatic, comparison: .greaterThan, threshold: 0, direction: .remaining)],
            thenToken: .pace(window: .weekly),
            elseToken: fallback)
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.providerName, .conditional(id: conditional.id)]])
        let options = self.options(conditionals: [conditional], colorPace: true)
        let colored = renderer.render(layout: layout, data: self.data(), icon: nil, options: options)
        #expect(colored.statusImage == nil)
        #expect(colored.accessibilityLabel.contains("+11%"))
        let neutral = renderer.render(
            layout: layout, data: self.data(automaticUsedPercent: 100), icon: nil, options: options)
        #expect(neutral.statusImage?.isTemplate == true)
        #expect(!neutral.accessibilityLabel.contains("+11%"))
    }

    @Test(arguments: ["aqua", "darkAqua"], ["regular", "stale", "highContrast", "staleHighContrast"])
    func `colored pace reaches native button across supported layouts`(appearance: String, mode: String) throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let button = NSButton()
        let options = self.options(
            isStale: mode == "stale" || mode == "staleHighContrast",
            colorPace: true,
            highContrast: mode == "highContrast" || mode == "staleHighContrast",
            appearanceName: appearance)
        for lines: [[MenuBarLayoutToken]] in [
            [[.pace(window: .weekly)]],
            [[.icon, .pace(window: .weekly)]],
            [[.providerName], [.pace(window: .weekly)]],
        ] {
            let output = renderer.render(
                layout: MenuBarLayout(lines: lines),
                data: self.data(),
                icon: icon,
                options: options)
            #expect(output.statusImage == nil)
            _ = StatusItemController.applyMenuBarLayoutContent(output, for: button, gap: .regular)
            let range = (button.attributedTitle.string as NSString).range(of: "\u{FFFC}", options: .backwards)
            try #require(range.location != NSNotFound)
            let expected = mode == "stale" ? NSColor.systemRed.withAlphaComponent(0.5) : .systemRed
            #expect(button.attributedTitle.attribute(
                .foregroundColor,
                at: range.location,
                effectiveRange: nil) as? NSColor
                == expected)
            #expect(button.accessibilityTitle() == output.accessibilityLabel)
        }
    }

    @Test
    func `stale pace colors remain dimmed`() {
        let rendered = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.pace(window: .weekly)]]),
            data: self.data(),
            icon: nil,
            options: self.options(isStale: true, colorPace: true))
        #expect(rendered.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == NSColor.systemRed.withAlphaComponent(0.5))
    }

    @Test(arguments: [false, true])
    func `high contrast preserves pace color without recoloring neutral tokens`(stale: Bool) {
        let renderer = MenuBarLayoutRenderer()
        for (token, expected): (MenuBarLayoutToken, NSColor) in [
            (.pace(window: .weekly), .systemRed),
            (.pace(window: .automatic), .labelColor),
            (.percent(window: .session), .labelColor),
        ] {
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[token]]),
                data: self.data(),
                icon: nil,
                options: self.options(isStale: stale, colorPace: true, highContrast: true))
            #expect(output.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == expected)
        }
    }

    private func renderToken(
        _ token: MenuBarLayoutToken,
        data: MenuBarLayoutRenderData? = nil,
        showUsed: Bool = true)
        -> MenuBarLayoutRenderedTitle
    {
        MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[token]]),
            data: data ?? self.data(),
            icon: nil,
            options: self.options(showUsed: showUsed))
    }

    @Test
    func `spend percent renders with the budget currency prefix and follows the used direction`() {
        let spend = L("Spend")
        let usd = self.renderToken(.percent(window: .spend))
        #expect(usd.attributedTitle.string == "$ 46%")
        #expect(usd.accessibilityLabel == L("%@ %@", spend, "46%"))
        #expect(self.renderToken(.percent(window: .spend), showUsed: false).attributedTitle.string == "$ 54%")

        var data = self.data()
        data.spendCurrencySymbol = "£"
        #expect(self.renderToken(.percent(window: .spend), data: data).attributedTitle.string == "£ 46%")
        data.spendCurrencySymbol = ""
        #expect(self.renderToken(.percent(window: .spend), data: data).attributedTitle.string == "46%")
    }

    @Test
    func `spend tokens render a dash without a budget`() {
        var data = self.data()
        data.spend = nil
        data.spendPace = nil
        data.spendAmount = nil
        data.spendBudget = nil
        let expected: [(MenuBarLayoutToken, String)] = [
            (.percent(window: .spend), "$ –"),
            (.pace(window: .spend), "–"),
            (.windowResetCountdown(window: .spend), "–"),
            (.windowResetAbsolute(window: .spend), "–"),
            (.spendAmount, "–"),
            (.spendBudget, "–"),
        ]
        for (token, text) in expected {
            #expect(self.renderToken(token, data: data).attributedTitle.string == text)
        }
        #expect(self.renderToken(.percent(window: .spend), data: data).accessibilityLabel
            == L("%@ unavailable", L("Spend")))
    }

    @Test
    func `spend pace renders its own delta and never borrows weekly pace`() {
        #expect(self.renderToken(.pace(window: .spend)).attributedTitle.string == "+6%")

        var data = self.data()
        data.spendPace = nil
        // Weekly pace is still resolved, yet the Spend token must not fall back to it.
        #expect(data.weeklyPace == "+11%")
        #expect(self.renderToken(.pace(window: .spend), data: data).attributedTitle.string == "–")

        // The pace color reads the Spend delta as well: a reserve is green while weekly pace is a deficit.
        var reserve = MenuBarLayoutRenderMetrics.unavailable
        reserve.spendPaceDelta = -6
        let colored = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.pace(window: .spend)]]),
            data: self.data(metrics: reserve),
            icon: nil,
            options: self.options(colorPace: true))
        #expect(colored.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == .systemGreen)
    }

    @Test
    func `spend reset tokens read the spend window`() {
        let reset = self.now.addingTimeInterval(12 * 24 * 60 * 60)
        let countdown = self.renderToken(.windowResetCountdown(window: .spend)).attributedTitle.string
        let absolute = self.renderToken(.windowResetAbsolute(window: .spend)).attributedTitle.string
        #expect(countdown == UsageFormatter.resetCountdownDescription(from: reset, now: self.now))
        #expect(absolute == UsageFormatter.resetDescription(from: reset, now: self.now))
        #expect(countdown != self.renderToken(.windowResetCountdown(window: .weekly)).attributedTitle.string)
    }

    @Test
    func `spend amount and budget render provider reported money`() {
        for (token, text) in [(MenuBarLayoutToken.spendAmount, "$460"), (.spendBudget, "$460 / $1,000")] {
            let rendered = self.renderToken(token)
            #expect(rendered.attributedTitle.string == text)
            #expect(rendered.accessibilityLabel == "\(L("Spend")) \(text)")
        }
    }

    /// The default spend window is 46% used, resets in 12 days (288h), and runs +6 points ahead of pace,
    /// while the weekly window resets in 72h at +11: every threshold below separates the two.
    @Test
    func `spend predicates read used and remaining percent`() {
        let usedAbove = { (threshold: Double, direction: MenuBarConditionalDirection) in
            self.branchText(self.clause(
                metric: .spend,
                comparison: .greaterThan,
                threshold: threshold,
                direction: direction))
        }
        #expect(usedAbove(40, .used) == "5h 25%")
        #expect(usedAbove(50, .used) == "in 2h")
        #expect(usedAbove(50, .remaining) == "5h 25%")
        #expect(usedAbove(60, .remaining) == "in 2h")
    }

    @Test
    func `spend resets in and pace predicates read their own datum`() {
        #expect(self.branchText(self.clause(
            metric: .spendResetsIn, comparison: .greaterThan, threshold: 200)) == "5h 25%")
        // The weekly window resets in 72h; borrowing it would make this branch true.
        #expect(self.branchText(self.clause(
            metric: .spendResetsIn, comparison: .lessThan, threshold: 100)) == "in 2h")
        #expect(self.branchText(self.clause(
            metric: .spendPace, comparison: .greaterThan, threshold: 5)) == "5h 25%")
        // Weekly pace is +11; borrowing it would make this branch true.
        #expect(self.branchText(self.clause(
            metric: .spendPace, comparison: .greaterThan, threshold: 8)) == "in 2h")
    }

    @Test
    func `spend amount predicate compares USD used and remaining and is false without a USD rate`() {
        #expect(self.branchText(self.clause(
            metric: .spendAmount, comparison: .greaterThan, threshold: 450)) == "5h 25%")
        #expect(self.branchText(self.clause(
            metric: .spendAmount, comparison: .greaterThan, threshold: 500, direction: .remaining)) == "5h 25%")
        #expect(self.branchText(self.clause(
            metric: .spendAmount, comparison: .greaterThan, threshold: 550, direction: .remaining)) == "in 2h")
        // Balance and cost amounts never answer for the budget.
        #expect(self.branchText(self.clause(
            metric: .spendAmount, comparison: .lessThan, threshold: 10)) == "in 2h")

        // Without a USD figure the datum is missing, even though the money token still renders.
        var unrated = self.data(metrics: .unavailable)
        unrated.spendAmount = "€390"
        #expect(self.branchText(
            self.clause(metric: .spendAmount, comparison: .greaterThanOrEqual, threshold: 0),
            data: unrated) == "in 2h")
    }

    @Test
    func `spend money tokens never substitute balance or local cost`() {
        var data = self.data()
        data.spendAmount = nil
        data.spendBudget = nil
        #expect(data.balance == "$12.34")
        #expect(data.costToday == "$1.25")
        #expect(data.cost30d == "$20.00")
        for token in [MenuBarLayoutToken.spendAmount, .spendBudget] {
            let rendered = self.renderToken(token, data: data)
            #expect(rendered.attributedTitle.string == "–")
            #expect(rendered.accessibilityLabel == L(
                "%@ unavailable",
                token.editorLabel(provider: data.provider.firstPartyProvider)))
        }
    }

    private static var missingData: MenuBarLayoutRenderData {
        MenuBarLayoutRenderData(
            provider: .codex,
            iconKey: "missing",
            providerName: nil,
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .codex, snapshot: nil),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            session: nil,
            weekly: nil,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: nil,
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

    func data(
        automaticUsedPercent: Double = 50,
        provider: UsageProvider = .codex,
        laneLabels: MenuBarLayoutLaneLabels? = nil,
        automaticResetAt: Date? = nil,
        automaticText: String? = nil,
        automaticBalanceFallback: String? = nil,
        accountLabel: String? = "user@example.com",
        extraRateWindows: [MenuBarLayoutRenderExtra] = [],
        omitsSession: Bool = false,
        sessionWindowMinutes: Int? = 300,
        weeklyUsedPercent: Double = 60,
        metrics: MenuBarLayoutRenderMetrics? = nil)
        -> MenuBarLayoutRenderData
    {
        MenuBarLayoutRenderData(
            provider: provider.instanceID,
            iconKey: "codex",
            providerName: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName,
            accountLabel: accountLabel,
            laneLabels: laneLabels ?? MenuBarLayoutLaneLabels(provider: provider, snapshot: nil),
            primary: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 10,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil)),
            secondary: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 9,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil)),
            tertiary: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 17,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil)),
            extraRateWindows: extraRateWindows,
            session: omitsSession ? nil : MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 25,
                windowMinutes: sessionWindowMinutes,
                resetsAt: self.now.addingTimeInterval(60 * 60),
                resetDescription: nil)),
            weekly: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: weeklyUsedPercent,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil)),
            scopedWeekly: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 80,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(24 * 60 * 60),
                resetDescription: nil)),
            scopedWeeklyTitle: "Fable only",
            automatic: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: automaticUsedPercent,
                windowMinutes: 300,
                resetsAt: automaticBalanceFallback == nil
                    ? automaticResetAt ?? self.now.addingTimeInterval(2 * 60 * 60) : nil,
                resetDescription: automaticBalanceFallback)),
            automaticText: automaticText,
            sessionPace: "-8%",
            weeklyPace: "+11%",
            automaticPace: "0%",
            runsOut: "Runs out in 1d 16h",
            balance: "$12.34",
            costToday: "$1.25",
            cost30d: "$20.00",
            // Numeric twins of the strings above, so conditional predicates and rendered text agree.
            metrics: metrics ?? MenuBarLayoutRenderMetrics(
                sessionPaceDelta: -8,
                weeklyPaceDelta: 11,
                automaticPaceDelta: 0,
                runsOutMinutes: 2400,
                balanceRemainingUSD: 12.34,
                balanceUsedUSD: 7.66,
                costTodayUSD: 1.25,
                cost30dUSD: 20,
                spendPaceDelta: 6,
                spendUsedUSD: 460,
                spendRemainingUSD: 540),
            spend: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 46,
                windowMinutes: 30 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(12 * 24 * 60 * 60),
                resetDescription: nil)),
            spendPace: "+6%",
            spendAmount: "$460",
            spendBudget: "$460 / $1,000")
    }

    func options(
        size: MenuBarLayoutSize = .regular,
        now: Date? = nil,
        showUsed: Bool = true,
        verticalAdjustment: Int = 0,
        isStale: Bool = false,
        conditionals: [MenuBarLayoutConditional] = [],
        isDebugApp: Bool = false,
        colorPace: Bool = false,
        colorByProvider: Bool = false,
        highContrast: Bool = false,
        appearanceName: String = "aqua",
        isHighlighted: Bool = false,
        forceStackedStyle: Bool = false,
        monospacedDigits: Bool = false,
        showWindowLabels: Bool = true) -> MenuBarLayoutRenderOptions
    {
        MenuBarLayoutRenderOptions(
            size: size,
            highContrast: highContrast,
            showUsed: showUsed,
            conditionals: conditionals,
            appearanceName: appearanceName,
            isDebugApp: isDebugApp,
            isStale: isStale,
            isHighlighted: isHighlighted,
            now: now ?? self.now,
            verticalAdjustment: verticalAdjustment,
            colorPace: colorPace,
            colorByProvider: colorByProvider,
            forceStackedStyle: forceStackedStyle,
            monospacedDigits: monospacedDigits,
            showWindowLabels: showWindowLabels)
    }

    private func averageBrightness(
        of title: NSAttributedString,
        appearance: NSAppearance.Name) throws
        -> CGFloat
    {
        try self.renderAverageBrightness(appearance: appearance) { _ in
            title.draw(at: NSPoint(x: 4, y: 4))
        }
    }

    private func renderAverageBrightness(
        appearance: NSAppearance.Name,
        draw: (NSImage) -> Void) throws
        -> CGFloat
    {
        let canvas = NSImage(size: NSSize(width: 24, height: 24))
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            canvas.lockFocus()
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: canvas.size).fill()
            draw(canvas)
            canvas.unlockFocus()
        }

        let data = try #require(canvas.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var totalBrightness: CGFloat = 0
        var visiblePixelCount = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                totalBrightness += color.brightnessComponent
                visiblePixelCount += 1
            }
        }
        return try totalBrightness / CGFloat(#require(visiblePixelCount > 0 ? visiblePixelCount : nil))
    }

    private func baselineOffset(in title: NSAttributedString, at index: Int) -> CGFloat? {
        let value = title.attribute(.baselineOffset, at: index, effectiveRange: nil)
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        return nil
    }
}

private final class MenuBarLayoutSizeCountingImage: NSImage {
    private let sizeReads = OSAllocatedUnfairLock(initialState: 0)

    var sizeReadCount: Int {
        self.sizeReads.withLock { $0 }
    }

    override var size: NSSize {
        get {
            self.sizeReads.withLock { $0 += 1 }
            return super.size
        }
        set {
            super.size = newValue
        }
    }
}

extension MenuBarLayoutRendererTests {
    @Test
    func `unlabelled default status item preserves the 0_65_0 width contract`() {
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: .defaultLayout, data: self.data(), icon: icon, options: self.options(showWindowLabels: false))
        #expect(output.attributedTitle.string == "\u{2009}50%")
        // Hiding window labels preserves the compact width used by v0.65.0.
        #expect(output.statusItemWidth(gap: .tight) == 49)
        #expect(output.statusItemWidth(gap: .regular) == 56)
        let iconOnly = renderer.render(
            layout: MenuBarLayout(lines: [[.icon]]), data: self.data(), icon: icon, options: self.options())
        #expect(iconOnly.statusItemWidth(gap: .tight) == 19)
        #expect(iconOnly.statusItemWidth(gap: .regular) == 26)
        print("STATUS_WIDTH default regular=\(output.statusItemWidth(gap: .regular)) "
            + "tight=\(output.statusItemWidth(gap: .tight)) iconOnly regular=26 tight=19")
    }

    @Test
    func `plain single line status content reuses a template image by value`() throws {
        let cache = MenuBarLayoutTitleCache(capacity: 2)
        let renderer = MenuBarLayoutRenderer(cache: cache)
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic), .pace(window: .weekly), .runsOutCompact]])
        let first = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options())
        let equivalent = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options())
        let image = try #require(first.statusImage)
        #expect(image.isTemplate)
        #expect(equivalent.statusImage === image)
        let expected = ceil(first.attributedTitle.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
        #expect(first.statusItemWidth(gap: .tight) == max(18, expected + 3))
        #expect(first.statusItemWidth(gap: .regular) == max(18, expected + 10))

        let changedData = self.data(automaticUsedPercent: 72)
        let changed = renderer.render(layout: layout, data: changedData, icon: nil, options: self.options())
        #expect(changed.statusImage !== image)
        let dark = self.options(appearanceName: "darkAqua")
        let darkOutput = renderer.render(layout: layout, data: changedData, icon: nil, options: dark)
        #expect(darkOutput.statusImage !== changed.statusImage)
        #expect(cache.count == 2)
        renderer.removeAll()
        let rebuilt = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options())
        #expect(rebuilt.statusImage !== image)
    }

    @Test
    func `rich stale and high contrast status layouts retain native titles`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let plain = MenuBarLayout(lines: [[.percent(window: .automatic)]])
        let highContrast = self.options(highContrast: true)
        let cases: [(MenuBarLayout, MenuBarLayoutRenderOptions)] = [
            (plain, self.options(isStale: true)),
            (plain, highContrast),
            (MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]), self.options()),
            (MenuBarLayout(lines: [[.icon]]), self.options()),
            (MenuBarLayout(lines: [[.hidden]]), self.options()),
        ]
        for (layout, options) in cases {
            #expect(renderer.render(layout: layout, data: self.data(), icon: icon, options: options).statusImage == nil)
        }
        let multiline = renderer.render(
            layout: MenuBarLayout(lines: [[.accountLabel]]),
            data: self.data(accountLabel: "Personal\nWork"),
            icon: nil,
            options: self.options())
        #expect(multiline.statusImage == nil)
    }

    @Test
    func `color glyphs retain native rendering while ordinary labels are cached`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.accountLabel]])
        for label in ["Ops 🦞", "Work ♥️", "Team 1️⃣", "Office 👩‍💻", "Office 🇦🇹"] {
            let output = renderer.render(
                layout: layout, data: self.data(accountLabel: label), icon: nil, options: self.options())
            #expect(output.statusImage == nil)
            #expect(output.attributedTitle.string == label)
        }
        let ordinary = renderer.render(
            layout: layout, data: self.data(accountLabel: "Personal"), icon: nil, options: self.options())
        #expect(ordinary.statusImage != nil)
    }

    @Test
    func `status content transitions keep accessibility and clear old image or title`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic)]])
        let plain = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options())
        let stale = renderer.render(layout: layout, data: self.data(), icon: nil, options: self.options(isStale: true))
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        for output in [plain, stale, plain] {
            let width = StatusItemController.applyMenuBarLayoutContent(output, for: button, gap: .regular)
            #expect(width == output.statusItemWidth(gap: .regular))
            #expect(button.accessibilityTitle() == output.accessibilityLabel)
            if let image = output.statusImage {
                #expect(button.image === image)
                #expect(button.imagePosition == .imageOnly)
                #expect(button.attributedTitle.length == 0)
            } else {
                #expect(button.image == nil)
                #expect(button.imagePosition == .noImage)
                #expect(button.attributedTitle.isEqual(to: output.attributedTitle))
            }
        }
    }

    @Test
    func `template drawing preserves logical size and vertical adjustment at both scales`() throws {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic), .pace(window: .weekly)]])
        var centroids: [Int: CGFloat] = [:]
        for shift in [-2, 0, 2] {
            let output = renderer.render(
                layout: layout, data: self.data(), icon: nil, options: self.options(verticalAdjustment: shift))
            let image = try #require(output.statusImage)
            #expect(image.size.height == 22)
            for scale in [1, 2] {
                let bitmap = try Self.statusBitmap(image: image, scale: scale)
                #expect(bitmap.pixelsWide == Int(image.size.width) * scale)
                #expect(bitmap.pixelsHigh == 22 * scale)
                var mass: CGFloat = 0
                var weightedY: CGFloat = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                        mass += alpha
                        weightedY += CGFloat(y) * alpha
                    }
                }
                #expect(mass > 10)
                let centroid = weightedY / mass / CGFloat(scale)
                if scale == 1 {
                    centroids[shift] = centroid
                } else {
                    #expect(abs(centroid - (centroids[shift] ?? -100)) < 1)
                }
            }
        }
        #expect(try abs(#require(centroids[-2]) - #require(centroids[2]) - 4) < 0.5)
    }

    @Test
    func `stacked monochrome icons percentages and resets share a native template`() throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        icon.isTemplate = true
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic), .resetCountdown]])
        let options = self.options(forceStackedStyle: true)
        let top = renderer.render(layout: layout, data: self.data(), icon: icon, options: options)
        let bottom = renderer.render(
            layout: layout, data: self.data(provider: .claude), icon: icon, options: options)
        let output = MenuBarLayoutRenderer.composeStackedProviderRows(
            top: top, bottom: bottom, topProviderName: "Codex", bottomProviderName: "Claude")
        let image = try #require(output.statusImage)
        #expect(image.isTemplate)
        #expect(image.size.height == 22)
        let button = NSButton()
        _ = StatusItemController.applyMenuBarLayoutContent(output, for: button, gap: .regular)
        #expect(button.image === image)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.attributedTitle.length == 0)
        #expect(button.accessibilityTitle() == output.accessibilityLabel)
        let bitmap = try Self.statusBitmap(image: image, scale: 2)
        var ink = [0, 0]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                ink[y < bitmap.pixelsHigh / 2 ? 0 : 1] += 1
            }
        }
        #expect(ink.allSatisfy { $0 > 50 }, "Both stacked rows must remain visible")
    }

    @Test
    func `stacked templates preserve colored provider marks warnings and second row emoji`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        let options = self.options(forceStackedStyle: true)
        let top = renderer.render(layout: layout, data: self.data(), icon: icon, options: options)
        func compose(_ bottom: MenuBarLayoutRenderedTitle) -> MenuBarLayoutRenderedTitle {
            MenuBarLayoutRenderer.composeStackedProviderRows(
                top: top, bottom: bottom, topProviderName: "Codex", bottomProviderName: "Claude")
        }
        let colored = renderer.render(
            layout: layout,
            data: self.data(provider: .claude),
            icon: icon,
            options: self.options(colorByProvider: true, forceStackedStyle: true))
        #expect(compose(colored).statusImage == nil)
        let warning = renderer.render(
            layout: layout,
            data: self.data(provider: .claude),
            icon: StatusItemController.quotaWarningFlashImage(base: icon),
            options: options)
        #expect(compose(warning).statusImage == nil)
        let emoji = renderer.render(
            layout: MenuBarLayout(lines: [[.accountLabel]]),
            data: self.data(provider: .claude, accountLabel: "Ops 🦞"),
            icon: nil,
            options: options)
        #expect(compose(emoji).statusImage == nil)
    }

    private static func statusBitmap(image: NSImage, scale: Int) throws -> NSBitmapImageRep {
        let context = try #require(CGContext(
            data: nil,
            width: Int(image.size.width) * scale,
            height: Int(image.size.height) * scale,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        image.draw(in: NSRect(origin: .zero, size: image.size))
        let bitmap = try NSBitmapImageRep(cgImage: #require(context.makeImage()))
        bitmap.size = image.size
        return bitmap
    }
}
