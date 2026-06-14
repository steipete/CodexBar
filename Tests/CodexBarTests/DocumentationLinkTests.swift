import Foundation
import Testing

struct DocumentationLinkTests {
    private enum DocumentationLinkError: Error, Equatable {
        case invalidURL(String)
        case outsideDocumentationRoot(String)
    }

    @Test
    func `readme local documentation links resolve`() throws {
        let root = try Self.repoRoot()
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        let links = try Self.markdownLinks(in: readme)
            .filter(Self.isRepositoryDocReference)

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

    @Test
    func `markdown links support standard destination syntax`() throws {
        let markdown = """
        [fragment](#section)
        [query](docs/guide%20name.md?mode=print#topic)
        [title](docs/title.md "Title")
        [angle](<docs/with space.md>)
        [reference][guide]

        [guide]: docs/reference.md?view=1#top
        `[code](docs/not-a-link.md)`
        ![image](docs/image.png)
        [external](https://example.com/docs/remote.md)
        """

        let links = try Self.markdownLinks(in: markdown)

        #expect(links == [
            "#section",
            "docs/guide%20name.md?mode=print#topic",
            "docs/title.md",
            "docs/with%20space.md",
            "docs/reference.md?view=1#top",
            "https://example.com/docs/remote.md",
        ])
        #expect(links.filter(Self.isRepositoryDocReference).count == 4)
    }

    @Test
    func `local documentation paths normalize safely`() throws {
        let root = URL(filePath: "/tmp/CodexBar-documentation-links", directoryHint: .isDirectory)

        let target = try Self.localDocURL(
            for: "./docs/guide%20name.md?mode=print#topic",
            repositoryRoot: root)
        #expect(target.path == "/tmp/CodexBar-documentation-links/docs/guide name.md")

        #expect(throws: DocumentationLinkError.outsideDocumentationRoot("docs/../README.md")) {
            try Self.localDocURL(for: "docs/%2E%2E/README.md", repositoryRoot: root)
        }
        #expect(!Self.isRepositoryDocReference("#section"))
        #expect(!Self.isRepositoryDocReference("https://example.com/docs/remote.md"))
    }

    @Test
    func `provider detail extraction ignores unrelated inline code`() {
        let markdown = """
        - Details: `docs/first.md#section`.
        - Example: `docs/not-a-detail.md`.
          - Details: `docs/second%20guide.md?mode=print`.
        See also: `docs/not-a-detail-either.md`.
        """

        #expect(Self.inlineCodeDocLinks(in: markdown) == [
            "docs/first.md#section",
            "docs/second%20guide.md?mode=print",
        ])
    }

    private static func markdownLinks(in text: String) throws -> [String] {
        let markdown = try AttributedString(markdown: text)
        return markdown.runs.compactMap { $0.link?.relativeString }
    }

    private static func inlineCodeDocLinks(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "- Details: `"
            guard trimmed.hasPrefix(prefix) else { return nil }
            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            guard let valueEnd = trimmed[valueStart...].firstIndex(of: "`") else { return nil }
            return String(trimmed[valueStart..<valueEnd])
        }
    }

    private static func expectLocalDocLink(_ rawLink: String, existsUnder root: URL) throws {
        let url = try Self.localDocURL(for: rawLink, repositoryRoot: root)
        #expect(
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "Missing local documentation target: \(rawLink)")
    }

    private static func isRepositoryDocReference(_ rawLink: String) -> Bool {
        guard let components = URLComponents(string: rawLink),
              components.scheme == nil,
              components.host == nil
        else {
            return false
        }
        var path = components.path[...]
        while path.hasPrefix("./") {
            path = path.dropFirst(2)
        }
        return path == "docs" || path.hasPrefix("docs/")
    }

    private static func localDocURL(for rawLink: String, repositoryRoot root: URL) throws -> URL {
        guard let components = URLComponents(string: rawLink),
              components.scheme == nil,
              components.host == nil,
              !components.path.isEmpty
        else {
            throw DocumentationLinkError.invalidURL(rawLink)
        }

        let target = root.appending(path: components.path).standardizedFileURL
        let docsRoot = root.appending(path: "docs", directoryHint: .isDirectory).standardizedFileURL
        guard target.path == docsRoot.path || target.path.hasPrefix(docsRoot.path + "/") else {
            throw DocumentationLinkError.outsideDocumentationRoot(components.path)
        }
        return target
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = dir.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            guard parent != dir else { break }
            dir = parent
        }
        throw NSError(domain: "DocumentationLinkTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root (Package.swift) from \(#filePath)",
        ])
    }
}
