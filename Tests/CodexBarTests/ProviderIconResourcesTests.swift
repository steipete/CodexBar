import AppKit
import Foundation
import Testing

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
            "crof",
            "commandcode",
            "t3chat",
            "kimi",
            "bedrock",
            "elevenlabs",
            "groq",
            "llmproxy",
            "deepgram",
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
