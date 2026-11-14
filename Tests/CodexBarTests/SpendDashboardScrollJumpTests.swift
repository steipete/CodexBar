import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class SpendDashboardScrollJumpTests: XCTestCase {
    func test_jumpingToBottomOfPaneShowsContent() async throws {
        let fixture = try await Self.makeFixture()
        let (settings, store) = (fixture.settings, fixture.store)
        defer { fixture.stop() }
        let host = NSHostingView(rootView: SpendDashboardPane(settings: settings, store: store)
            .frame(width: 760, height: 560)
            .environment(\.locale, Locale(identifier: "en_US")))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 760, height: 560),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await Self.layout(host)

        let scroll = try XCTUnwrap(Self.views(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(Self.drawnFraction(scroll.contentView), 0.01, "detector must see the top of the pane")

        // Jumps like pressing End or dragging the scroller: lazy height estimates must settle onto real rows.
        for fraction in [1.0, 0.5, 0.8, 1.0] {
            let maxY = document.bounds.height - scroll.contentView.bounds.height
            document.scroll(NSPoint(x: 0, y: max(0, maxY * fraction)))
            await Self.layout(host)

            XCTAssertLessThanOrEqual(scroll.contentView.bounds.maxY, document.bounds.height + 0.5)
            XCTAssertGreaterThan(
                Self.drawnFraction(scroll.contentView),
                0.01,
                "pane rendered blank after jumping to \(fraction)")
        }
    }

    @MainActor
    struct Fixture {
        let settings: SettingsStore
        let store: UsageStore
        let controller: SpendDashboardController

        func stop() {
            self.controller.stop()
            self.store.stopSharedSpendDashboardPublication()
            self.settings.configFileWatcher?.stop()
        }
    }

    /// Synthetic 90-day dashboard with no provider transport, shared by the layout and lifetime tests.
    static func makeFixture() async throws -> Fixture {
        let settings = testSettingsStore(
            suiteName: "SpendDashboardScrollJump",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        enableTestProviders([.cursor, .opencode], settings: settings)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.preferredCurrencyCode = "USD"
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_providerRefreshOverride = { _ in XCTFail("Synthetic layout must not start a provider transport") }
        store._test_widgetSnapshotSaveOverride = { _ in }
        let now = Date()
        let configuration = SpendDashboardSource.configuration(settings: settings, store: store)
        let inputs = SpendDashboardNativeProofTests.syntheticInputs(now: now, calendar: configuration.bucketCalendar)
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { mode in
                SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: inputs,
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: now,
                    force: mode.forcesLoader)
            },
            loader: { request in
                SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            },
            nowProvider: { now },
            publicationHandler: { store.spendDashboardPublication = $0 })
        store.sharedSpendDashboardControllerStorage = controller
        controller.selectPeriod(.rolling(days: 90))
        controller.update(configuration: configuration)
        try await SpendDashboardStateWait.until { !controller.isRefreshing && !controller.model.groups.isEmpty }
        return Fixture(settings: settings, store: store, controller: controller)
    }

    private static func layout(_ host: NSView) async {
        for _ in 0..<6 {
            host.window?.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private static func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(self.views)
    }

    /// Share of visible pixels that differ from the most common colour, i.e. anything drawn over the background.
    private static func drawnFraction(_ view: NSView) -> Double {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let key = (UInt32(color.redComponent * 31) << 10)
                    | (UInt32(color.greenComponent * 31) << 5)
                    | UInt32(color.blueComponent * 31)
                counts[key, default: 0] += 1
                total += 1
            }
        }
        guard total > 0, let background = counts.values.max() else { return 0 }
        return Double(total - background) / Double(total)
    }
}
