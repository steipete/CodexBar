import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct IconRendererWeeklyTimeMarkerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func weeklyWindow(hoursLeft: Double, minutes: Int? = 10080) -> RateWindow {
        RateWindow(
            usedPercent: 40,
            windowMinutes: minutes,
            resetsAt: self.now.addingTimeInterval(hoursLeft * 3600),
            resetDescription: nil)
    }

    @Test
    func `marker follows time left when bars show remaining quota`() throws {
        // 42 of 168 hours left = 25%.
        let percent = try #require(IconRemainingResolver.secondaryTimeMarkerPercent(
            window: self.weeklyWindow(hoursLeft: 42),
            showUsed: false,
            now: self.now))
        #expect(abs(percent - 25) < 0.0001)
    }

    @Test
    func `marker follows elapsed time when bars show used quota`() throws {
        let percent = try #require(IconRemainingResolver.secondaryTimeMarkerPercent(
            window: self.weeklyWindow(hoursLeft: 42),
            showUsed: true,
            now: self.now))
        #expect(abs(percent - 75) < 0.0001)
    }

    @Test
    func `marker is absent without a usable reset window`() {
        let stale = self.weeklyWindow(hoursLeft: -1)
        let tooFar = self.weeklyWindow(hoursLeft: 200)
        let noDuration = self.weeklyWindow(hoursLeft: 10, minutes: nil)
        for window in [stale, tooFar, noDuration] {
            #expect(IconRemainingResolver.secondaryTimeMarkerPercent(
                window: window,
                showUsed: false,
                now: self.now) == nil)
        }
        #expect(IconRemainingResolver.secondaryTimeMarkerPercent(window: nil, showUsed: false, now: self.now) == nil)
    }

    @Test
    func `marker pixel maps percent onto the bar width`() {
        #expect(IconRenderer.timeMarkerPixel(nil, rectWidth: 30) == -1)
        #expect(IconRenderer.timeMarkerPixel(0, rectWidth: 30) == 0)
        #expect(IconRenderer.timeMarkerPixel(50, rectWidth: 30) == 15)
        #expect(IconRenderer.timeMarkerPixel(140, rectWidth: 30) == 30)
    }

    @Test(arguments: [MenuBarWeekProgressStyle.caret, .line, .dottedLine])
    func `each marker style changes the icon and tracks the percent`(style: MenuBarWeekProgressStyle) throws {
        func render(_ marker: Double?) throws -> Data {
            try #require(IconRenderer.makeIcon(
                primaryRemaining: 60,
                weeklyRemaining: 80,
                creditsRemaining: nil,
                stale: false,
                style: .codex,
                hideCritters: true,
                weeklyTimeMarkerPercent: marker,
                weeklyTimeMarkerStyle: style).tiffRepresentation)
        }
        let plain = try render(nil)
        #expect(try render(30) != plain)
        #expect(try render(30) != render(60))
    }
}
