import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class UserPluginCardPresentationTests: XCTestCase {
    func test_headerOmitsSourceFilenameAndLocalizesIdentityLabels() throws {
        let fixture = try UserProviderPluginTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plugin = try Self.plugin(fixture: fixture)
        try Self.withLanguage("zh-Hans") {
            let hosting = Self.hosting(plugin: plugin, language: "zh-Hans", dark: false)
            _ = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            let text = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
            XCTAssertTrue(text.contains(plugin.manifest.name), text)
            XCTAssertFalse(text.contains(plugin.fileURL.lastPathComponent), text)
            XCTAssertTrue(text.contains(L("Plan")), text)
        }
    }

    func test_renderSyntheticCards() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_PLUGIN_CARD_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PLUGIN_CARD_SCREENSHOT_DIR to render synthetic plugin cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try UserProviderPluginTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plugin = try Self.plugin(fixture: fixture)
        for language in ["en", "zh-Hans"] {
            try Self.withLanguage(language) {
                for dark in [false, true] {
                    let hosting = Self.hosting(plugin: plugin, language: language, dark: dark)
                    let data = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    let name = "plugin-card-\(language)-\(dark ? "dark" : "light").png"
                    try data.write(to: directory.appendingPathComponent(name))
                }
            }
        }
    }

    private static func withLanguage<T>(_ language: String, operation: () throws -> T) rethrows -> T {
        try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
            UsageFormatter.setLocalizationProvider { L($0, language: language) }
            UsageFormatter.setLocaleProvider { Locale(identifier: language) }
            defer {
                UsageFormatter.clearLocalizationProvider()
                UsageFormatter.clearLocaleProvider()
            }
            return try operation()
        }
    }

    private static func plugin(fixture: UserProviderPluginTests.Fixture) throws -> UserProviderPlugin {
        try fixture.loader(transport: UserProviderPluginTests.RecordingTransport(responseJSON: "{}"))
            .load(fileURL: fixture.write(name: "fixture-card.js", source: """
            defineProvider({
              id: "fixture-card", name: "Fixture Provider", endpoints: ["https://fixture.example"], settings: [],
              icon: { monogram: "FX", tint: "#336699",
                svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M3 8h4v8H3zM10 3h4v18h-4zM17 6h4v12h-4z"/></svg>' },
              fetchUsage() { return { primary: { usedPercent: 25 } }; },
            });
            """))
    }

    private static func hosting(
        plugin: UserProviderPlugin,
        language: String,
        dark: Bool) -> NSHostingView<AnyView>
    {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: plugin.manifest.id,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Fixture Plus"))
        let view = AnyView(UserPluginMenuCardView(
            plugin: plugin,
            snapshot: snapshot,
            error: nil,
            isRefreshing: false,
            showUsed: true,
            resetStyle: .countdown,
            width: 320,
            onRefresh: {})
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.displayScale, 2)
            .environment(\.accessibilityEnabled, true)
            .background(Color(nsColor: .windowBackgroundColor)))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return hosting
    }
}
