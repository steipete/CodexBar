import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct PluginIconReuseTests {
    @Test
    func `plugin icons reuse unchanged rasters and bound retired revisions`() throws {
        let fixture = try UserProviderPluginTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let loader = fixture.loader(transport: UserProviderPluginTests.RecordingTransport(responseJSON: "{}"))
        let plugin = try loader.load(fileURL: fixture.write(name: "icon.js", source: Self.source()))
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }
        let first = Self.icon(plugin)
        for _ in 0..<20 {
            #expect(Self.icon(plugin) === first)
        }
        #expect(first.isTemplate)
        #expect(first.size == NSSize(width: 16, height: 16))
        let pixels = try #require(first.tiffRepresentation)
        let sameSVG = try loader.load(fileURL: fixture.write(
            name: "same-icon.js",
            source: Self.source() + "\n// Same SVG"))
        #expect(Self.icon(sameSVG) === first)
        let changed = try loader.load(fileURL: fixture.write(name: "icon.js", source: Self.source(inset: 6)))
        let changedImage = Self.icon(changed)
        #expect(changedImage !== first)
        #expect(changedImage.tiffRepresentation != pixels)
        #expect(Self.icon(changed) === changedImage)

        for revision in 0..<64 {
            let source = Self.source(inset: Double(revision + 1) / 100)
            _ = try Self.icon(loader.load(fileURL: fixture.write(name: "icon.js", source: source)))
        }
        let reloaded = Self.icon(plugin)
        #expect(reloaded !== first)
        #expect(reloaded.tiffRepresentation == pixels)
        #expect(Self.icon(plugin) === reloaded)
    }

    @Test
    func `plugin icon cache follows the evaluated SVG across supported engines`() throws {
        let fixture = try UserProviderPluginTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = UserProviderPluginTests.RecordingTransport(responseJSON: "{}")
        let source = """
        const width = typeof Intl === "undefined" ? 4 : 12;
        defineProvider({
          id: "engine-icon", name: "Engine Icon", endpoints: ["https://fixture.example"], settings: [],
          icon: { monogram: "FX", tint: "#336699",
            svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="${width}" height="16"/></svg>` },
          fetchUsage() { return { primary: { usedPercent: 25 } }; },
        });
        """
        let url = try fixture.write(name: "engine-icon.js", source: source)
        let hash = try fixture.loader(transport: transport).load(fileURL: url).sourceHash
        let plugins = try [ProviderPluginEngineKind.quickJS, .javaScriptCore].map { engine in
            let runtime = try ProviderPluginRuntime(
                source: source,
                transport: transport,
                responseSizeLimit: UserProviderPlugin.maximumSourceBytes,
                enforcesUserResponsePolicy: true,
                allowsDynamicID: true,
                engine: engine)
            return UserProviderPlugin(
                fileURL: url, sourceHash: hash, transpiledCacheURL: nil, transpileCacheHit: false, runtime: runtime)
        }
        let quickSVG = try #require(plugins[0].manifest.icon.svg)
        let jscSVG = try #require(plugins[1].manifest.icon.svg)
        try #require(quickSVG != jscSVG)
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }
        let narrow = Self.icon(plugins[0])
        let wide = Self.icon(plugins[1])
        #expect(narrow !== wide)
        let narrowBitmap = try #require(narrow.representations.first as? NSBitmapImageRep)
        let wideBitmap = try #require(wide.representations.first as? NSBitmapImageRep)
        #expect(try #require(narrowBitmap.colorAt(x: 16, y: 16)).alphaComponent < 0.1)
        #expect(try #require(wideBitmap.colorAt(x: 16, y: 16)).alphaComponent > 0.9)
        #expect(transport.requestCount == 0)
    }

    @Test
    func `text only switchers do not request provider or plugin images`() throws {
        let fixture = try UserProviderPluginTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plugin = try fixture.loader(transport: UserProviderPluginTests.RecordingTransport(responseJSON: "{}"))
            .load(fileURL: fixture.write(name: "icon.js", source: Self.source()))
        var imageRequests = 0
        var selection: ProviderSwitcherSelection?
        let view = ProviderSwitcherView(
            providers: [.codex],
            pluginProviders: [plugin],
            selected: .overview,
            includesOverview: true,
            width: 360,
            showsIcons: false,
            iconProvider: { _ in imageRequests += 1; return NSImage() },
            pluginIconProvider: { _ in imageRequests += 1; return NSImage() },
            weeklyRemainingProvider: { _ in 75 },
            onSelect: { selection = $0 })
        view.layoutSubtreeIfNeeded()
        #expect(imageRequests == 0)
        #expect(view._test_segmentTitles().count == 3)
        #expect(view._test_segmentTitles().last == plugin.manifest.name)
        #expect(view._test_simulateRuntimeClick(buttonTag: 2))
        #expect(selection == .provider(plugin.manifest.id))
    }

    private static func icon(_ plugin: UserProviderPlugin) -> NSImage {
        StatusItemController.userPluginSwitcherIcon(for: plugin, snapshot: nil, brandIcon: { _ in nil })
    }

    private static func source(inset: Double = 2) -> String {
        """
        defineProvider({
          id: "fixture-icon", name: "Fixture Icon", endpoints: ["https://fixture.example"], settings: [],
          icon: { monogram: "FX", tint: "#336699",
            svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M\(inset) 2h6v12H\(inset)z"/></svg>' },
          fetchUsage() { return { primary: { usedPercent: 25 } }; },
        });
        """
    }
}
