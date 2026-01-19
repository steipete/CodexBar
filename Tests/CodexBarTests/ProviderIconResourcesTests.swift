import AppKit
import Foundation
import Testing

@MainActor
@Suite
struct ProviderIconResourcesTests {
    @Test
    func providerIconSVGsExist() throws {
        let root = try Self.repoRoot()
        let resources = root.appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)

        let slugs = [
            "codex",
            "claude",
            "zai",
            "minimax",
            "cursor",
            "opencode",
            "gemini",
            "antigravity",
            "factory",
            "copilot",
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
