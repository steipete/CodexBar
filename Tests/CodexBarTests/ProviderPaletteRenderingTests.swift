import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarWidget

@MainActor
struct ProviderPaletteRenderingTests {
    @Test(arguments: ProviderPaletteRegressionTests.palettes)
    func `menu bar brand icons keep system template tint`(_ palette: ProviderPaletteRegressionTests.Palette) throws {
        let icon = try #require(ProviderBrandIcon.image(for: palette.provider))
        #expect(icon.isTemplate)
    }

    @Test
    func `render synthetic palette comparisons`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_PALETTE_PROOF_DIR"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let audit = try String(contentsOf: root.appendingPathComponent("docs/provider-palette.md"), encoding: .utf8)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let palettes = ProviderPaletteRegressionTests.palettes
        for page in 0..<4 {
            let entries = Array(palettes[(page * 9)..<((page + 1) * 9)])
            let proposals = try entries.map { palette in
                let line = try #require(audit.split(separator: "\n").first {
                    $0.hasPrefix("| \(palette.provider.rawValue) |")
                })
                let value = line.split(separator: "|")[2].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "`", with: "")
                return try #require(ProviderColor(hexString: value))
            }
            let view = VStack(alignment: .leading, spacing: 12) {
                Text("Provider palette · synthetic production views · \(page + 1)/4").font(.title2.bold())
                Text(
                    "Menu-card rows: old / proposed / final. Status icon remains a template. Widget rows: old / final.")
                    .font(.caption)
                Text(
                    "Fixed white and #222222 surfaces; 62% usage. " +
                        "No account data or live app. WidgetKit compositor simulated.")
                    .font(.caption)
                ForEach(entries.indices, id: \.self) { index in
                    let palette = entries[index]
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text(palette.provider.rawValue).bold()
                            Text(ProviderColor(hex: palette.final).hexString).font(.caption.monospaced())
                        }.frame(width: 115, alignment: .leading)
                        self.menu(palette, proposed: proposals[index], dark: false)
                        self.menu(palette, proposed: proposals[index], dark: true)
                        self.widget(palette, dark: false)
                        self.widget(palette, dark: true)
                    }
                }
            }
            .padding(20)
            .background(Color(red: 0.91, green: 0.92, blue: 0.94))
            .foregroundStyle(.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("palette-final-\(page + 1).png"))
        }
    }

    private func menu(_ palette: ProviderPaletteRegressionTests.Palette, proposed: ProviderColor, dark: Bool)
        -> some View
    {
        let colors = [ProviderColor(hex: palette.old), proposed, ProviderColor(hex: palette.final)]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let icon = ProviderBrandIcon.image(for: palette.provider) {
                    Image(nsImage: icon).renderingMode(.template).resizable().frame(width: 18, height: 18)
                }
                Text("62% · \(dark ? "Dark" : "Light") menu").font(.caption)
            }
            ForEach(colors.indices, id: \.self) { index in
                UsageProgressBar(percent: 62, tint: Self.color(colors[index]), accessibilityLabel: "Synthetic usage")
            }
        }
        .padding(12).frame(width: 235)
        .background(dark ? Self.color(ProviderColor(hex: 0x222222)) : .white)
        .foregroundStyle(dark ? .white : .black)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func widget(_ palette: ProviderPaletteRegressionTests.Palette, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(dark ? "Dark" : "Light") widget").font(.caption)
            QuotaBar(percent: 62, color: Self.color(ProviderColor(hex: palette.widget))).frame(height: 6)
            QuotaBar(
                percent: 62,
                color: Self.color(ProviderDescriptorRegistry.descriptor(for: palette.provider).branding.widgetColor))
                .frame(height: 6)
            Text("RGB preserved").font(.caption2)
        }
        .padding(12).frame(width: 165)
        .background(dark ? Self.color(ProviderColor(hex: 0x222222)) : .white)
        .foregroundStyle(dark ? .white : .black)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private static func color(_ color: ProviderColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }
}
