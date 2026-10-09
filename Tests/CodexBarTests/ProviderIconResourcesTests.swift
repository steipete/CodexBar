import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderIconResourcesTests {
    @Test
    func `groq and grok provider icons are distinct`() throws {
        let root = try Self.repoRoot()
        let resources = root.appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)
        let groq = try String(contentsOf: resources.appending(path: "ProviderIcon-groq.svg"), encoding: .utf8)
        let grok = try String(contentsOf: resources.appending(path: "ProviderIcon-grok.svg"), encoding: .utf8)

        #expect(groq != grok)
    }

    @Test
    func `grok and xai provider icons are distinct`() throws {
        let root = try Self.repoRoot()
        let resources = root.appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)
        let grok = try String(contentsOf: resources.appending(path: "ProviderIcon-grok.svg"), encoding: .utf8)
        let xai = try String(contentsOf: resources.appending(path: "ProviderIcon-xai.svg"), encoding: .utf8)

        #expect(grok != xai)
    }

    @Test
    func `provider brand icons are cached after first load`() throws {
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }

        let first = try #require(ProviderBrandIcon.image(for: .codex))
        let second = try #require(ProviderBrandIcon.image(for: .codex))

        #expect(first === second)
        #expect(first.size == NSSize(width: 18, height: 18))
        #expect(first.isTemplate)
    }

    @Test(arguments: [UsageProvider.ollama, .llmman])
    func `provider icons use template rendering`(provider: UsageProvider) throws {
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }

        let image = try #require(ProviderBrandIcon.image(for: provider))

        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate)

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()

        var visiblePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide
                where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
            {
                visiblePixels += 1
            }
        }
        #expect(visiblePixels > 40)
        #expect(visiblePixels < 240)
    }

    @Test
    func `pi provider icon is a transparent vector template`() throws {
        let root = try Self.repoRoot()
        let resourceURL = root
            .appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)
            .appending(path: "ProviderIcon-pi.svg")
        let svg = try String(contentsOf: resourceURL, encoding: .utf8)

        #expect(!svg.contains("<text"))
        #expect(!svg.contains("<circle"))
        #expect(svg.contains("fill=\"currentColor\""))
        #expect(svg.contains("viewBox=\"0 0 560 560\""))
        for path in [
            "M420 280H280V140H0V0H420V280Z",
            "M560 560H420V280H560V560Z",
            "M140 560H0V140H140V280H280V420H140V560Z",
        ] {
            #expect(svg.contains("d=\"\(path)\""))
        }
        let website = try String(contentsOf: root.appending(path: "docs/logos/pi.svg"), encoding: .utf8)
        #expect(website == svg)
        let cli = try String(
            contentsOf: root.appending(path: "Sources/CodexBarCLI/CLIServeProviderIcons.swift"), encoding: .utf8)
        #expect(cli.contains("\"ProviderIcon-pi\": \"\(Data(svg.utf8).base64EncodedString())\""))

        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }
        let image = try #require(ProviderBrandIcon.image(for: .pi))
        #expect(image.isTemplate)

        if let proofPath = ProcessInfo.processInfo.environment["CODEXBAR_PI_ICON_PROOF"] {
            let proof = NSImage(size: NSSize(width: 256, height: 128), flipped: false) { _ in
                for (index, background) in [NSColor.white, .black].enumerated() {
                    let tile = NSRect(x: index * 128, y: 0, width: 128, height: 128)
                    background.setFill()
                    tile.fill()
                    let glyph = NSImage(size: tile.size, flipped: false) { rect in
                        image.draw(in: rect.insetBy(dx: 24, dy: 24))
                        (index == 0 ? NSColor.black : .white).setFill()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    glyph.draw(in: tile)
                }
                return true
            }
            let data = try #require(proof.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: proofPath))
        }

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()

        var visiblePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide
                where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
            {
                visiblePixels += 1
            }
        }
        #expect(visiblePixels > 20)
        #expect(visiblePixels < 180)
    }

    @Test
    func `registered providers resolve bundled brand icons`() {
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }

        for provider in UsageProvider.allCases {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            #expect(
                ProviderBrandIcon.image(for: provider) != nil,
                "Missing icon resource \(descriptor.branding.iconResourceName).svg for \(provider.rawValue)")
        }
    }

    @Test(arguments: [UsageProvider.claude, .codex, .antigravity, .mistral, .muse, .bedrock, .vertexai])
    func `brand and monochrome images have independent caches`(provider: UsageProvider) throws {
        for brandFirst in [false, true] {
            ProviderBrandIcon.resetCacheForTesting()
            let firstStyle: ProviderBrandIcon.Style = brandFirst ? .brand : .monochrome
            let secondStyle: ProviderBrandIcon.Style = brandFirst ? .monochrome : .brand
            let first = try #require(ProviderBrandIcon.image(for: provider, style: firstStyle))
            let second = try #require(ProviderBrandIcon.image(for: provider, style: secondStyle))
            #expect(first !== second)
            #expect(first.isTemplate == !brandFirst)
            #expect(second.isTemplate == brandFirst)
            #expect(ProviderBrandIcon.image(for: provider, style: firstStyle) === first)
            #expect(ProviderBrandIcon.image(for: provider, style: secondStyle) === second)
            #expect(ProviderBrandIcon.image(for: provider)?.isTemplate == true)
        }
        ProviderBrandIcon.resetCacheForTesting()
    }

    @Test(arguments: [UsageProvider.cursor, .pi, .openai, .azureopenai])
    func `brand requests without curated assets retain adaptive templates`(provider: UsageProvider) throws {
        let image = try #require(ProviderBrandIcon.image(for: provider, style: .brand))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test(arguments: [UsageProvider.claude, .codex, .antigravity, .mistral, .muse, .bedrock, .vertexai])
    func `curated brand resources render color and transparent padding`(provider: UsageProvider) throws {
        let image = try #require(ProviderBrandIcon.image(for: provider, style: .brand))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        var coloredPixels = 0
        var warmPixels = 0
        var greenPixels = 0
        for y in 0..<64 {
            for x in 0..<64 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5 else { continue }
                if color.redComponent > color.blueComponent + 0.1 { warmPixels += 1 }
                if color.greenComponent > color.blueComponent + 0.1 { greenPixels += 1 }
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                if (components.max() ?? 0) - (components.min() ?? 0) > 0.1 {
                    coloredPixels += 1
                }
            }
        }
        #expect(coloredPixels > 100)
        if provider == .antigravity {
            // A native SVG decoder can silently flatten the official blurred gradient to blue.
            #expect(warmPixels > 5)
            #expect(greenPixels > 5)
        }
        #expect((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0)
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "ProviderIconResourcesTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root (Package.swift) from \(#filePath)",
        ])
    }
}
