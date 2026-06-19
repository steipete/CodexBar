import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderIconResourcesTests {
    @Test
    func `provider icon SV gs exist`() throws {
        let root = try Self.repoRoot()
        let resources = root.appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)

        let slugs = [
            "codex",
            "claude",
            "zai",
            "minimax",
            "cursor",
            "opencode",
            "opencodego",
            "alibaba",
            "gemini",
            "antigravity",
            "factory",
            "copilot",
            "devin",
            "crof",
            "commandcode",
            "t3chat",
            "kimi",
            "bedrock",
            "elevenlabs",
            "groq",
            "llmproxy",
            "litellm",
            "deepgram",
            "ollama",
        ]
        for slug in slugs {
            let url = resources.appending(path: "ProviderIcon-\(slug).svg")
            #expect(
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                "Missing SVG for \(slug)")

            let image = NSImage(contentsOf: url)
            #expect(image != nil, "Could not load SVG as NSImage for \(slug)")
        }
    }

    @Test
    func `groq and grok provider icons are distinct`() throws {
        let root = try Self.repoRoot()
        let resources = root.appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)
        let groq = try String(contentsOf: resources.appending(path: "ProviderIcon-groq.svg"), encoding: .utf8)
        let grok = try String(contentsOf: resources.appending(path: "ProviderIcon-grok.svg"), encoding: .utf8)

        #expect(groq != grok)
    }

    @Test
    func `provider brand icons are cached after first load`() throws {
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }

        let first = try #require(ProviderBrandIcon.image(for: .codex))
        let second = try #require(ProviderBrandIcon.image(for: .codex))

        #expect(first === second)
        #expect(first.size == NSSize(width: 16, height: 16))
        #expect(first.isTemplate)
    }

    @Test
    func `ollama provider icon uses template rendering`() throws {
        ProviderBrandIcon.resetCacheForTesting()
        defer { ProviderBrandIcon.resetCacheForTesting() }

        let image = try #require(ProviderBrandIcon.image(for: .ollama))

        #expect(image.size == NSSize(width: 16, height: 16))
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
