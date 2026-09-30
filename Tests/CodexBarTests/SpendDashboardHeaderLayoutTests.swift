import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class SpendDashboardHeaderLayoutTests: XCTestCase {
    func test_headerFitsNarrowSettingsInBothAppearances() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let settings = testSettingsStore(
                suiteName: "SpendDashboardHeaderLayout",
                userDefaults: InMemoryUserDefaults(),
                config: testConfigWithAllProvidersDisabled())
            settings.costUsageEnabled = true
            let store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing,
                environmentBase: [:])
            store.sharedSpendDashboardControllerStorage = SpendDashboardController(
                userDefaults: InMemoryUserDefaults(),
                requestBuilder: { _ in fatalError("Rendering the header must not load spend data") })
            defer {
                store.stopSharedSpendDashboardPublication()
                settings.configFileWatcher?.stop()
            }
            for dark in [false, true] {
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let view = SpendDashboardPane(settings: settings, store: store).header
                    .frame(width: 520, alignment: .leading)
                    .padding(24)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = appearance
                let size = hosting.fittingSize
                XCTAssertEqual(size.width, 568, accuracy: 1)
                XCTAssertLessThan(size.height, 150, "Title and subtitle must not collapse beside the range picker")
                hosting.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(
                    contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentView = hosting
                defer { window.contentView = nil }
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                if let directory = ProcessInfo.processInfo.environment["CODEXBAR_HEADER_PROOF_DIR"] {
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "4064-header-\(dark ? "dark" : "light").png"
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }
}
