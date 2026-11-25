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

    @Test
    func `zero weekly quota keeps its time marker`() throws {
        func render(_ marker: Double?) throws -> Data {
            try #require(IconRenderer.makeIcon(
                primaryRemaining: 60,
                weeklyRemaining: 0,
                creditsRemaining: nil,
                stale: false,
                style: .claude,
                hideCritters: true,
                weeklyTimeMarkerPercent: marker,
                weeklyTimeMarkerStyle: .line).tiffRepresentation)
        }
        #expect(try render(50) != render(nil))
    }

    @Test
    func `next marker update lands on the next pixel boundary`() throws {
        let width = IconRenderer.timeMarkerBarWidthPx
        let window = self.weeklyWindow(hoursLeft: 40)
        let change = try #require(IconRemainingResolver.nextTimeMarkerPixelChange(
            window: window,
            rectWidth: width,
            now: self.now))
        func pixel(at date: Date) -> Int {
            IconRenderer.timeMarkerPixel(
                IconRemainingResolver.secondaryTimeMarkerPercent(window: window, showUsed: false, now: date),
                rectWidth: width)
        }
        #expect(change > self.now)
        #expect(pixel(at: change.addingTimeInterval(-1)) == pixel(at: self.now))
        #expect(pixel(at: change.addingTimeInterval(1)) != pixel(at: self.now))
    }

    @Test
    func `last marker update is the reset`() {
        let window = self.weeklyWindow(hoursLeft: 1)
        #expect(IconRemainingResolver.nextTimeMarkerPixelChange(
            window: window,
            rectWidth: IconRenderer.timeMarkerBarWidthPx,
            now: self.now) == window.resetsAt)
        #expect(IconRemainingResolver.nextTimeMarkerPixelChange(
            window: self.weeklyWindow(hoursLeft: -1),
            rectWidth: IconRenderer.timeMarkerBarWidthPx,
            now: self.now) == nil)
    }

    @Test
    func `marker skips providers whose lower lane is not weekly`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "IconRendererWeeklyTimeMarkerTests-semantic-lane"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarWeekProgressStyle = .line
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar.system)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: self.weeklyWindow(hoursLeft: 42),
            updatedAt: self.now)
        #expect(controller.menuBarWeeklyTimeMarkerPercent(
            provider: .claude,
            snapshot: snapshot,
            showUsed: false,
            now: self.now) != nil)
        #expect(controller.menuBarWeeklyTimeMarkerPercent(
            provider: .kimi,
            snapshot: snapshot,
            showUsed: false,
            now: self.now) == nil)
    }
}
