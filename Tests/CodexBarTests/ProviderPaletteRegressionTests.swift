import CodexBarCore
import Foundation
import Testing

struct ProviderPaletteRegressionTests {
    struct Palette: Sendable {
        let provider: UsageProvider
        let old: UInt32
        let final: UInt32
        let widget: UInt32

        init(_ provider: UsageProvider, _ old: UInt32, _ final: UInt32, _ widget: UInt32) {
            self.provider = provider
            self.old = old
            self.final = final
            self.widget = widget
        }
    }

    static let palettes: [Palette] = [
        .init(.abacus, 0x38BDF8, 0x814EE8, 0x38BDF8),
        .init(.aiand, 0xE25C2B, 0xE25C2B, 0xE25C2B),
        .init(.amp, 0xDC2626, 0xF34E3F, 0xDC2626),
        .init(.augment, 0x6366F1, 0x1AA049, 0x6366F1),
        .init(.bedrock, 0xFF9900, 0x01A88D, 0xFF9900),
        .init(.chutes, 0x3184FF, 0x3184FF, 0x18A058),
        .init(.clawrouter, 0x596EF6, 0x596EF6, 0x596EF6),
        .init(.clinepass, 0x61A3FA, 0x5487C8, 0x61A3FA),
        .init(.codebuff, 0x44FF00, 0x00FF95, 0x44FF00),
        .init(.commandcode, 0xA04DFD, 0x8C4EDD, 0x000000),
        .init(.copilot, 0xA855F7, 0xA855F7, 0xA855F7),
        .init(.cursor, 0x00BFA5, 0xF54E00, 0x00BFA5),
        .init(.deepseek, 0x527DF0, 0x4D6BFE, 0x527DF0),
        .init(.deepgram, 0x6467F2, 0x6467F2, 0x0A121B),
        .init(.devin, 0x46B482, 0x317CFF, 0x46B482),
        .init(.doubao, 0x3370FF, 0x3370FF, 0x2D88FF),
        .init(.fireworks, 0xF25B1C, 0xF25B1C, 0xF25B1C),
        .init(.groq, 0xF56844, 0xF56844, 0xF56844),
        .init(.jetbrains, 0xFF3399, 0xFF3399, 0xFF3399),
        .init(.kilo, 0xF27027, 0xF27027, 0xF27027),
        .init(.kimi, 0xFE603C, 0xFE603C, 0xFE603C),
        .init(.kiro, 0xFF9900, 0x9046FF, 0xFF9900),
        .init(.litellm, 0x4C89F0, 0x4C89F0, 0x4C89F0),
        .init(.longcat, 0xFFD100, 0x29E154, 0xFFD100),
        .init(.mistral, 0xFF500F, 0xFF5229, 0xFF500F),
        .init(.moonshot, 0x205DEB, 0x205DEB, 0x205DEB),
        .init(.neuralwatt, 0x38D98C, 0xD55934, 0x38D98C),
        .init(.notion, 0x337EA9, 0x337EA9, 0x337EA9),
        .init(.opencode, 0x3B82F6, 0x3B82F6, 0x3B82F6),
        .init(.perplexity, 0x20B2AA, 0x20B2AA, 0x20B2AA),
        .init(.qoder, 0x10B981, 0x10B981, 0x10B981),
        .init(.sakana, 0x2975DB, 0x2975DB, 0x2975DB),
        .init(.sub2api, 0x2DC6D8, 0x14B8A6, 0x2DC6D8),
        .init(.t3chat, 0xF56647, 0xF56647, 0xF56647),
        .init(.venice, 0x3399FF, 0x3C8FDD, 0x3399FF),
        .init(.warp, 0x938BB4, 0x938BB4, 0x938BB4),
    ]

    @Test(arguments: Self.palettes)
    func `audited accents and existing widget colors stay pinned`(_ palette: Palette) {
        let branding = ProviderDescriptorRegistry.descriptor(for: palette.provider).branding
        #expect(branding.color == ProviderColor(hex: palette.final))
        #expect(branding.widgetColor.hexString == ProviderColor(hex: palette.widget).hexString)
    }

    @Test(arguments: Self.palettes)
    func `palette does not introduce material light or dark contrast regressions`(_ palette: Palette) {
        let color = ProviderDescriptorRegistry.descriptor(for: palette.provider).branding.color
        let old = ProviderColor(hex: palette.old)
        // Controlled menu/card surfaces, not a certification of all translucent desktop backgrounds.
        for background in [ProviderColor(hex: 0xFFFFFF), ProviderColor(hex: 0x222222)] {
            let current = Self.contrast(color, background)
            let previous = Self.contrast(old, background)
            #expect(current >= 3 || previous - current < 0.5)
        }
    }

    @Test
    func `moonshot keeps its original confetti ink`() {
        let palette = ProviderDescriptorRegistry.descriptor(for: .moonshot).branding.confettiPalette
        #expect(palette.first == ProviderColor(hex: 0x121212))
    }

    @Test(arguments: Self.palettes)
    func `website and audit table match the app accent`(_ palette: Palette) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let hex = ProviderDescriptorRegistry.descriptor(for: palette.provider).branding.color.hexString
        let index = try String(contentsOf: root.appendingPathComponent("docs/index.html"), encoding: .utf8)
        let card = try #require(index.split(separator: "\n").first {
            $0.contains("data-provider=\"\(palette.provider.rawValue)\"")
        })
        #expect(card.contains("--brand:\(hex)"))

        let audit = try String(contentsOf: root.appendingPathComponent("docs/provider-palette.md"), encoding: .utf8)
        let row = try #require(audit.split(separator: "\n").first {
            $0.hasPrefix("| \(palette.provider.rawValue) |")
        })
        #expect(row.split(separator: "|")[3].trimmingCharacters(in: .whitespaces) == "`\(hex)`")

        let social = try String(contentsOf: root.appendingPathComponent("docs/social.html"), encoding: .utf8)
        let name = palette.provider == .kimi ? "Kimi" : ProviderDefaults.metadata[palette.provider]?.displayName
        if let name, let tile = social.split(separator: "\n").first(where: {
            $0.contains("<div class=\"name\">\(name)</div>")
        }) {
            #expect(tile.contains("--brand:\(hex)"))
        }
    }

    private static func contrast(_ color: ProviderColor, _ background: ProviderColor) -> Double {
        let foreground = Self.luminance(color)
        let backdrop = Self.luminance(background)
        return (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
    }

    private static func luminance(_ color: ProviderColor) -> Double {
        let linear = [color.red, color.green, color.blue].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
