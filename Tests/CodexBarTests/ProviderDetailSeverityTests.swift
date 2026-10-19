import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct ProviderDetailSeverityTests {
    @Test(arguments: [ProviderPluginEngineKind.quickJS, .javaScriptCore])
    func `both plugin engines preserve row severity and consumed progress`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine, rows: """
        {label:"Normal", value:"60%", progress:0.4, severity:"normal"},
        {label:"Warning", value:"40%", progress:0.6, severity:"warning"},
        {label:"Critical", value:"10%", progress:0.9, severity:"critical"},
        {label:"Legacy", value:"25%", progress:0.75},
        {label:"Null", value:"25%", severity:null}
        """)
        let rows = try #require(snapshot.details.first?.rows)
        #expect(rows.map(\.severity) == [.normal, .warning, .critical, nil, nil])
        #expect(rows.map { $0.progress?.usedPercent } == [40, 60, 90, 75, nil])
        let decoded = try JSONDecoder().decode([ProviderDetailSection.Row].self, from: JSONEncoder().encode(rows))
        #expect(decoded == rows)
        let legacy = try JSONDecoder().decode(
            ProviderDetailSection.Row.self, from: Data(#"{"label":"Legacy","value":"25%"}"#.utf8))
        #expect(legacy.severity == nil)
    }

    @Test(arguments: [ProviderPluginEngineKind.quickJS, .javaScriptCore])
    func `both engines reject unknown and nonstring severity`(engine: ProviderPluginEngineKind) async throws {
        for severity in [#""orange""#, "42", #""""#] {
            await #expect(throws: (any Error).self) {
                _ = try await Self.fetch(engine: engine, rows: "{label:'Row', value:'1', severity:\(severity)}")
            }
        }
    }

    @MainActor
    @Test
    func `severity survives provider localization`() throws {
        let row = try ProviderDetailSection.Row(
            label: "user@example.com", value: "10%", progress: .init(used: 0.9, total: 1), severity: .critical)
        let section = try ProviderDetailSection(rows: [row])
        for provider in [UsageProvider.synthetic, .deepseek] {
            let localized = UsageMenuCardView.Model.localizedProviderDetails([section], provider: provider)
            #expect(localized.first?.rows.first?.severity == .critical)
        }
    }

    @MainActor
    @Test
    func `detail bars render independent severity colors and retain the legacy tint`() throws {
        let severities: [ProviderDetailSection.Row.Severity?] = [.normal, .warning, .critical, nil]
        let rows = try severities.enumerated().map { index, severity in
            try ProviderDetailSection.Row(
                label: "Pool \(index)", value: "1 / 1", progress: .init(used: 1, total: 1), severity: severity)
        }
        let section = try ProviderDetailSection(rows: rows)
        let renderer = ImageRenderer(content: ProviderDetailSectionsContent(sections: [section], chartColor: .blue)
            .frame(width: 280).padding(12).background(.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var counts = [0, 0, 0, 0]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else {
                    continue
                }
                let r = color.redComponent
                let g = color.greenComponent
                let b = color.blueComponent
                if r < 0.5, g > 0.45, b < 0.5 { counts[0] += 1 }
                if r > 0.65, g > 0.35, g < 0.8, b < 0.35 { counts[1] += 1 }
                if r > 0.65, g < 0.35, b < 0.35 { counts[2] += 1 }
                if r < 0.4, b > 0.6 { counts[3] += 1 }
            }
        }
        // Each full bar covers thousands of pixels; a small status glyph alone cannot satisfy this.
        #expect(counts.allSatisfy { $0 > 1000 }, "Expected green/orange/red/legacy blue bars: \(counts)")
    }

    private static func fetch(engine: ProviderPluginEngineKind, rows: String) async throws -> UsageSnapshot {
        let source = """
        defineProvider({id:"fixture-severity", name:"Fixture", endpoints:["https://example.com"], settings:[],
          fetchUsage() { return { details:[{rows:[\(rows)]}] }; }
        });
        """
        return try await ProviderPluginRuntime(source: source, allowsDynamicID: true, engine: engine).fetchUsage()
    }
}
