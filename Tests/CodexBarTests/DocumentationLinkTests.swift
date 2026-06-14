import Foundation
import Testing

struct DocumentationLinkTests {
    @Test
    func `readme local documentation links resolve`() throws {
        let root = try Self.repoRoot()
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        let links = Self.markdownLinks(in: readme)
            .filter { $0.hasPrefix("docs/") }

        #expect(!links.isEmpty)
        for link in links {
            try Self.expectLocalDocLink(link, existsUnder: root)
        }
    }

    @Test
    func `provider overview detail docs resolve`() throws {
        let root = try Self.repoRoot()
        let providers = try String(
            contentsOf: root.appending(path: "docs/providers.md"),
            encoding: .utf8)
        let links = Self.inlineCodeDocLinks(in: providers)

        #expect(!links.isEmpty)
        for link in links {
            try Self.expectLocalDocLink(link, existsUnder: root)
        }
    }

    private static func markdownLinks(in text: String) -> [String] {
        let pattern = #"\]\(([^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let linkRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[linkRange])
        }
    }

    private static func inlineCodeDocLinks(in text: String) -> [String] {
        let pattern = #"`(docs/[^`#]+(?:#[^`]*)?)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let linkRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[linkRange])
        }
    }

    private static func expectLocalDocLink(_ rawLink: String, existsUnder root: URL) throws {
        let link = rawLink.split(separator: "#", maxSplits: 1).first.map(String.init) ?? rawLink
        let decoded = link.removingPercentEncoding ?? link
        let url = root.appending(path: decoded)
        #expect(
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "Missing local documentation target: \(rawLink)")
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
        throw NSError(domain: "DocumentationLinkTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root (Package.swift) from \(#filePath)",
        ])
    }
}
