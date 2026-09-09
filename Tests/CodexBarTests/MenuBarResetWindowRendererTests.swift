import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension MenuBarLayoutRendererTests {
    @Test
    func `selected reset accessibility composes the window and value without repeated prepositions`() {
        let data = self.data()
        for window in [PercentWindow.session, .weekly, .scopedWeekly] {
            let label = switch window {
            case .session: "Session"
            case .weekly: "Weekly"
            default: data.scopedWeeklyTitle ?? "Scoped weekly"
            }
            for absolute in [false, true] {
                let token: MenuBarLayoutToken = absolute
                    ? .windowResetAbsolute(window: window) : .windowResetCountdown(window: window)
                let output = MenuBarLayoutRenderer().render(
                    layout: MenuBarLayout(lines: [[token]]), data: data, icon: nil, options: self.options())
                #expect(output.accessibilityLabel == "\(label): \(output.attributedTitle.string)")
            }
        }
        let text = "Friday at 10:00"
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.windowResetCountdown(window: .weekly)]]),
            data: self.resetData(weekly: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: text)),
            icon: nil,
            options: self.options())
        #expect(output.accessibilityLabel == "Weekly: \(text)")
    }

    @Test
    func `selected reset windows render independently of automatic`() throws {
        let renderer = MenuBarLayoutRenderer()
        for window in [PercentWindow.session, .weekly, .scopedWeekly] {
            let data = self.data()
            let selected = switch window {
            case .session: data.session
            case .weekly: data.weekly
            default: data.scopedWeekly
            }
            for absolute in [false, true] {
                let token: MenuBarLayoutToken = absolute
                    ? .windowResetAbsolute(window: window) : .windowResetCountdown(window: window)
                let output = renderer.render(
                    layout: MenuBarLayout(lines: [[token]]),
                    data: data,
                    icon: nil,
                    options: self.options())
                let reset = try #require(selected?.resetsAt)
                let expected = absolute
                    ? UsageFormatter.resetDescription(
                        from: reset,
                        now: self.now)
                    : UsageFormatter.resetCountdownDescription(
                        from: reset,
                        now: self.now)
                #expect(output.attributedTitle.string == expected)
            }
        }
    }

    @Test
    func `selected reset does not fall back to automatic for missing or synthetic windows`() {
        let synthetic = RateWindow(
            usedPercent: 0,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(600),
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        for weekly in [nil, synthetic] {
            for token in [
                MenuBarLayoutToken.windowResetCountdown(window: .weekly),
                .windowResetAbsolute(window: .weekly),
            ] {
                let output = MenuBarLayoutRenderer().render(
                    layout: MenuBarLayout(lines: [[token]]),
                    data: self.resetData(weekly: weekly),
                    icon: nil,
                    options: self.options())
                #expect(output.attributedTitle.string == "–")
            }
        }
    }

    @Test
    func `selected reset uses its own provider text without a date`() {
        let weekly = RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: "Friday at 10:00")
        for token in [MenuBarLayoutToken.windowResetCountdown(window: .weekly), .windowResetAbsolute(window: .weekly)] {
            let output = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[token]]),
                data: self.resetData(weekly: weekly),
                icon: nil,
                options: self.options())
            #expect(output.attributedTitle.string == "Friday at 10:00")
        }
    }

    @Test
    func `selected countdown invalidates cache while automatic text stays unchanged`() {
        let renderer = MenuBarLayoutRenderer()
        let reset = self.now.addingTimeInterval(6 * 60 + 50)
        let data = self.resetData(weekly: RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: reset,
            resetDescription: nil))
        let layout = MenuBarLayout(lines: [[.windowResetCountdown(window: .weekly)]])
        let first = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: self.now))
        let same = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: self.now.addingTimeInterval(20)))
        let next = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: self.now.addingTimeInterval(51)))
        #expect(first.attributedTitle.string == "in 7m")
        #expect(first.attributedTitle === same.attributedTitle)
        #expect(next.attributedTitle.string == "in 6m")
        #expect(first.attributedTitle !== next.attributedTitle)
    }

    @Test
    func `selected absolute reset invalidates cache across local midnight`() throws {
        let calendar = Calendar.current
        let midnight = try #require(calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: self.now)))
        let before = midnight.addingTimeInterval(-1)
        let after = midnight.addingTimeInterval(1)
        let reset = midnight.addingTimeInterval(3600)
        let data = self.resetData(weekly: RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: reset,
            resetDescription: nil))
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.windowResetAbsolute(window: .weekly)]])
        let first = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: before))
        let next = renderer.render(
            layout: layout,
            data: data,
            icon: nil,
            options: self.options(now: after))
        #expect(first.attributedTitle.string == UsageFormatter.resetDescription(
            from: reset,
            now: before))
        #expect(next.attributedTitle.string == UsageFormatter.resetDescription(
            from: reset,
            now: after))
        #expect(first.attributedTitle.string != next.attributedTitle.string)
        #expect(first.attributedTitle !== next.attributedTitle)
    }

    private func resetData(weekly: RateWindow?) -> MenuBarLayoutRenderData {
        MenuBarLayoutRenderData(
            provider: .codex,
            iconKey: "codex",
            providerName: "Codex",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(
                provider: .codex,
                snapshot: nil),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            session: nil,
            weekly: MenuBarLayoutRenderWindow(weekly),
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: "Automatic unchanged")),
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

    @Test
    func `write synthetic reset token render proof when requested`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_RESET_TOKEN_PROOF_DIR"] else { return }
        let renderer = MenuBarLayoutRenderer()
        let canvas = NSImage(size: NSSize(
            width: 560,
            height: 330))
        let appearance = try #require(NSAppearance(named: .aqua))
        appearance.performAsCurrentDrawingAppearance {
            canvas.lockFocus()
            defer { canvas.unlockFocus() }
            NSColor.white.setFill()
            NSRect(
                origin: .zero,
                size: canvas.size).fill()
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black,
            ]
            NSAttributedString(
                string: "Reset window selections — synthetic fixture",
                attributes: labelAttributes)
                .draw(at: NSPoint(
                    x: 24,
                    y: 295))
            for (index, token) in MenuBarLayoutPaletteTokens.time.prefix(6).enumerated() {
                let y = CGFloat(250 - index * 40)
                NSAttributedString(
                    string: token.editorLabel(provider: .codex),
                    attributes: labelAttributes)
                    .draw(at: NSPoint(
                        x: 24,
                        y: y))
                let rendered = renderer.render(
                    layout: MenuBarLayout(lines: [[token]]),
                    data: self.data(),
                    icon: nil,
                    options: self.options())
                rendered.attributedTitle.draw(at: NSPoint(
                    x: 310,
                    y: y))
            }
        }
        let tiff = try #require(canvas.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(representation.representation(
            using: .png,
            properties: [:]))
        let output = URL(
            fileURLWithPath: directory,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true)
        try png.write(
            to: output.appendingPathComponent("reset-window-tokens.png"),
            options: .atomic)
    }
}
