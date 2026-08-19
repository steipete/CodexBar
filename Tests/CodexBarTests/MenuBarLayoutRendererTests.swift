import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarLayoutRendererTests {
    private let now = Date(timeIntervalSince1970: 1_752_768_000)

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
            (.cost30d, "$20.00"),
            (.separatorDot, "·"),
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
        let missingData = MenuBarLayoutRenderData(
            provider: .codex,
            iconKey: "missing",
            providerName: nil,
            accountLabel: nil,
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
            cost30d: nil)
        let layout = MenuBarLayout(lines: [[
            .icon,
            .providerName,
            .accountLabel,
            .percent(window: .session),
            .percent(window: .weekly),
            .percent(window: .scopedWeekly),
            .percent(window: .automatic),
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
            .cost30d,
        ]])

        let output = renderer.render(layout: layout, data: missingData, icon: nil, options: self.options())

        #expect(output.attributedTitle.string.count(where: { $0 == "–" }) == 18)
        #expect(output.accessibilityLabel.contains("unavailable"))
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
            cost30d: nil)

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

    @Test
    func `two line icon uses compact paragraph metrics`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let output = renderer.render(
            layout: MenuBarLayout(lines: [
                [.icon, .percent(window: .session)],
                [.percent(window: .weekly)],
            ]),
            data: self.data(),
            icon: icon,
            options: self.options())
        let bounds = output.attributedTitle.boundingRect(
            with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        #expect(output.attributedTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) is NSParagraphStyle)
        #expect(bounds.height <= 22)
    }

    @Test
    func `cached path renders one thousand titles under budget`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic), .separatorDot, .resetCountdown]])
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let first = renderer.render(layout: layout, data: self.data(), icon: icon, options: self.options())
        var last = first
        var fastest = Duration.seconds(10)

        // Best-of-three keeps the frozen 50 ms budget while ignoring one-off CI preemption.
        for _ in 0..<3 {
            let startedAt = ContinuousClock.now
            for _ in 0..<1000 {
                last = renderer.render(layout: layout, data: self.data(), icon: icon, options: self.options())
            }
            fastest = min(fastest, ContinuousClock.now - startedAt)
        }

        #expect(first.attributedTitle === last.attributedTitle)
        #expect(fastest < .milliseconds(50), "Fastest cached batch took \(fastest)")
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
                appearanceName: "aqua",
                isDebugApp: false,
                now: self.now))

        #expect(output.attributedTitle.string == "▮▮▮")
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
            cost30d: nil)

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

    @Test
    func `conditional renders then branch when predicate true`() {
        let renderer = MenuBarLayoutRenderer()
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 0)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let data = self.data()

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(conditional)]]),
            data: data,
            icon: nil,
            options: self.options())
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == control.attributedTitle.string)
        #expect(output.attributedTitle.string == "5h 25%")
    }

    @Test
    func `conditional renders else branch when predicate false`() {
        let renderer = MenuBarLayoutRenderer()
        // Session is 25%, so a > 50 threshold fails and the else branch must win.
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 50)],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        let data = self.data()

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(conditional)]]),
            data: data,
            icon: nil,
            options: self.options())
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.resetCountdown]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == control.attributedTitle.string)
        #expect(output.attributedTitle.string == "in 2h")
    }

    @Test
    func `hidden branch renders nothing`() {
        let renderer = MenuBarLayoutRenderer()
        // Session is 25%, so > 50 fails and the else branch (.hidden) wins, contributing nothing.
        let conditional = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 50)],
            thenToken: .percent(window: .session),
            elseToken: .hidden)

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(conditional)]]),
            data: self.data(),
            icon: nil,
            options: self.options())
        #expect(output.attributedTitle.string.isEmpty)
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
            layout: MenuBarLayout(lines: [[.conditional(falseConditional)]]),
            data: data,
            icon: nil,
            options: self.options())
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
            layout: MenuBarLayout(lines: [[.conditional(trueConditional)]]),
            data: data,
            icon: nil,
            options: self.options())
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
            layout: MenuBarLayout(lines: [[.conditional(conditional)]]),
            data: data,
            icon: nil,
            options: self.options())
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
        let data = MenuBarLayoutRenderData(
            provider: .codex,
            iconKey: "missing",
            providerName: nil,
            accountLabel: nil,
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
            cost30d: nil)

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(conditional)]]),
            data: data,
            icon: nil,
            options: self.options())
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
        // Build a chain 10 levels deep; the renderer caps traversal at maxConditionalDepth.
        var inner = MenuBarLayoutConditional(
            clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 0)],
            thenToken: .percent(window: .session),
            elseToken: .space)
        for _ in 0..<9 {
            inner = MenuBarLayoutConditional(
                clauses: [self.clause(metric: .session, comparison: .greaterThan, threshold: 0)],
                thenToken: .conditional(inner),
                elseToken: .space)
        }
        let data = self.data()
        // The cap triggers before any branch is evaluated, independent of live values,
        // so the missing-value placeholder is the expected title.
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.conditional(inner)]]),
            data: data,
            icon: nil,
            options: self.options())

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
            layout: MenuBarLayout(lines: [[.conditional(conditional)]]),
            data: data,
            icon: nil,
            options: self.options())
        let control = renderer.render(
            layout: MenuBarLayout(lines: [[.percent(window: .session)]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.accessibilityLabel == control.accessibilityLabel)
        #expect(output.accessibilityLabel == L("%@ %@", L("Session"), "25%"))
    }

    private func clause(
        metric: MenuBarConditionalMetric,
        comparison: MenuBarConditionalComparison,
        threshold: Double,
        combinator: MenuBarConditionalCombinator? = nil) -> MenuBarConditionalClause
    {
        MenuBarConditionalClause(
            combinator: combinator,
            predicate: MenuBarConditionalPredicate(metric: metric, comparison: comparison, threshold: threshold))
    }

    private func data(
        automaticUsedPercent: Double = 50,
        provider: UsageProvider = .codex,
        automaticResetAt: Date? = nil)
        -> MenuBarLayoutRenderData
    {
        MenuBarLayoutRenderData(
            provider: provider,
            iconKey: "codex",
            providerName: "Codex",
            accountLabel: "user@example.com",
            session: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(60 * 60),
                resetDescription: nil)),
            weekly: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 60,
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
                resetsAt: automaticResetAt ?? self.now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil)),
            automaticText: nil,
            sessionPace: "-8%",
            weeklyPace: "+11%",
            automaticPace: "0%",
            runsOut: "Runs out in 1d 16h",
            balance: "$12.34",
            costToday: "$1.25",
            cost30d: "$20.00")
    }

    private func options(
        now: Date? = nil,
        verticalAdjustment: Int = 0,
        isStale: Bool = false) -> MenuBarLayoutRenderOptions
    {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: false,
            showUsed: true,
            appearanceName: "aqua",
            isDebugApp: false,
            isStale: isStale,
            now: now ?? self.now,
            verticalAdjustment: verticalAdjustment)
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
