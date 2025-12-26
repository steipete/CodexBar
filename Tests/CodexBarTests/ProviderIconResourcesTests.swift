import AppKit
import Foundation
import Testing

@MainActor
@Suite
struct ProviderIconResourcesTests {
    @Test
    func providerIconPNGsExistAndHaveExpectedSizes() throws {
        let root = try Self.repoRoot()
        let resources = root.appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)

        let slugs = ["codex", "claude", "zai", "cursor", "gemini", "antigravity"]
        for slug in slugs {
            let url1x = resources.appending(path: "ProviderIcon-\(slug).png")
            let url2x = resources.appending(path: "ProviderIcon-\(slug)@2x.png")

            #expect(FileManager.default.fileExists(atPath: url1x.path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: url2x.path(percentEncoded: false)))

            let rep1x = try Self.bitmapRep(at: url1x)
            #expect(rep1x.pixelsWide == 16)
            #expect(rep1x.pixelsHigh == 16)
            #expect(rep1x.hasAlpha)

            let rep2x = try Self.bitmapRep(at: url2x)
            #expect(rep2x.pixelsWide == 32)
            #expect(rep2x.pixelsHigh == 32)
            #expect(rep2x.hasAlpha)
        }
    }

    private static func bitmapRep(at url: URL) throws -> NSBitmapImageRep {
        let data = try Data(contentsOf: url)
        guard let rep = NSBitmapImageRep(data: data) else {
            throw NSError(domain: "ProviderIconResourcesTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not decode PNG at \(url.path(percentEncoded: false))",
            ])
        }
        return rep
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
