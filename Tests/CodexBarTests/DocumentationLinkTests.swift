import Foundation
import Testing

struct DocumentationLinkTests {
    private enum DocumentationLinkError: Error, Equatable {
        case invalidURL(String)
        case missingAnchor(String)
        case missingTarget(String)
        case outsideDocumentationRoot(String)
    }

    @Test
    func `readme local documentation destinations resolve`() throws {
        let root = try Self.repoRoot()
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        let links = try (
            Self.markdownLinks(in: readme) +
                Self.markdownImageLinks(in: readme) +
                Self.htmlLinks(in: readme))
            .filter(Self.isRepositoryDocReference)

        #expect(!links.isEmpty)
        for link in links {
            try Self.validateLocalDocLink(link, existsUnder: root)
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
            try Self.validateLocalDocLink(link, existsUnder: root)
        }
    }

    @Test
    func `markdown links support standard destination syntax`() throws {
        let markdown = [
            "[fragment](#section)",
            "[query](docs/guide%20name.md?mode=print#topic)",
            #"[title](docs/title.md "Title")"#,
            "[angle](<docs/with space.md>)",
            "[reference][guide]",
            "",
            "[guide]: docs/reference.md?view=1#top",
            "`[code](docs/not-a-link.md)`",
            "![image](docs/image.png)",
            "[external](https://example.com/docs/remote.md)",
        ].joined(separator: "\n")

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
    func `markdown images support standard inline destination syntax`() {
        let markdown = """
        ![simple](docs/simple.png)
        ![query](docs/query.png?raw=1#preview)
        ![title](docs/title.png "Title")
        ![angle](<docs/with space.png>)
        `![inline code](docs/not-an-image.png)`
        ~~~markdown
        ![fenced code](docs/not-an-image-either.png)
        ~~~
        """

        #expect(Self.markdownImageLinks(in: markdown) == [
            "docs/simple.png",
            "docs/query.png?raw=1#preview",
            "docs/title.png",
            "docs/with space.png",
        ])
    }

    @Test
    func `html links support quoted and unquoted destinations`() {
        let html = """
        <img src="docs/double.png" alt="double">
        <a href='docs/single.md#section'>single</a>
        <img src=docs/unquoted.png alt=unquoted>
        <a href="https://example.com/docs/remote.md">external</a>
        `<img src="docs/not-an-image.png">`
        ~~~html
        <img src="docs/not-an-image-either.png">
        ~~~
        """

        #expect(Self.htmlLinks(in: html) == [
            "docs/double.png",
            "docs/single.md#section",
            "docs/unquoted.png",
            "https://example.com/docs/remote.md",
        ])
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
    func `markdown fragments resolve to rendered heading anchors`() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DocumentationLinkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let docs = root.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let guide = docs.appending(path: "guide.md")
        try """
        # Guide
        ## T3 Chat
        ## CLI default selection (`--source auto`)
        ## Repeated
        ## Repeated
        ~~~markdown
        ## Code Only
        ~~~
        """.write(to: guide, atomically: true, encoding: .utf8)

        try Self.validateLocalDocLink("docs/guide.md#t3-chat", existsUnder: root)
        try Self.validateLocalDocLink("docs/guide.md#cli-default-selection---source-auto", existsUnder: root)
        try Self.validateLocalDocLink("docs/guide.md#repeated-1", existsUnder: root)
        #expect(throws: DocumentationLinkError.missingAnchor("docs/guide.md#cli-default-selection")) {
            try Self.validateLocalDocLink("docs/guide.md#cli-default-selection", existsUnder: root)
        }
        #expect(throws: DocumentationLinkError.missingAnchor("docs/guide.md#renamed")) {
            try Self.validateLocalDocLink("docs/guide.md#renamed", existsUnder: root)
        }
        #expect(throws: DocumentationLinkError.missingAnchor("docs/guide.md#code-only")) {
            try Self.validateLocalDocLink("docs/guide.md#code-only", existsUnder: root)
        }
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

    private static func markdownImageLinks(in text: String) -> [String] {
        let pattern =
            #"\!\[(?:\\.|[^\]\\])*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))"# +
            #"(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^)\n]*\)))?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = Self.markdownTextOutsideCode(in: text)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            for index in 1...2 {
                if let linkRange = Range(match.range(at: index), in: source) {
                    return String(source[linkRange])
                }
            }
            return nil
        }
    }

    private static func htmlLinks(in text: String) -> [String] {
        let pattern =
            #"<\s*(?:a|img)\b[^>]*?\b(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let source = Self.markdownTextOutsideCode(in: text)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            for index in 1...3 {
                if let linkRange = Range(match.range(at: index), in: source) {
                    return String(source[linkRange])
                }
            }
            return nil
        }
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

    private static func validateLocalDocLink(_ rawLink: String, existsUnder root: URL) throws {
        let url = try Self.localDocURL(for: rawLink, repositoryRoot: root)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw DocumentationLinkError.missingTarget(rawLink)
        }

        guard url.pathExtension.lowercased() == "md",
              let fragment = URLComponents(string: rawLink)?.fragment,
              !fragment.isEmpty
        else {
            return
        }
        let markdown = try String(contentsOf: url, encoding: .utf8)
        guard Self.markdownHeadingAnchors(in: markdown).contains(fragment) else {
            throw DocumentationLinkError.missingAnchor(rawLink)
        }
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

    private static func markdownHeadingAnchors(in markdown: String) -> Set<String> {
        var occurrences: [String: Int] = [:]
        var anchors: Set<String> = []
        let source = Self.markdownTextOutsideFencedCode(in: markdown)
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let markerCount = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(markerCount),
                  trimmed.dropFirst(markerCount).first?.isWhitespace == true
            else {
                continue
            }
            let heading = trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces)
            guard let base = Self.markdownHeadingSlug(heading), !base.isEmpty else { continue }
            let occurrence = occurrences[base, default: 0]
            anchors.insert(occurrence == 0 ? base : "\(base)-\(occurrence)")
            occurrences[base] = occurrence + 1
        }
        return anchors
    }

    private static func markdownHeadingSlug(_ heading: String) -> String? {
        guard let rendered = try? AttributedString(markdown: heading) else { return nil }
        var slug = ""
        for scalar in String(rendered.characters).lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                slug.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                slug.append("-")
            }
        }
        return slug
    }

    private static func markdownTextOutsideCode(in markdown: String) -> String {
        self.markdownTextOutsideFencedCode(in: markdown)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { self.removingInlineCode(from: String($0)) }
            .joined(separator: "\n")
    }

    private static func markdownTextOutsideFencedCode(in markdown: String) -> String {
        var fence: (marker: Character, count: Int)?
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if let activeFence = fence {
                if Self.isClosingFence(line, marker: activeFence.marker, minimumCount: activeFence.count) {
                    fence = nil
                }
                return ""
            }
            if let openingFence = Self.openingFence(in: line) {
                fence = openingFence
                return ""
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func openingFence(in line: Substring) -> (marker: Character, count: Int)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return nil }
        let candidate = line.dropFirst(leadingSpaces)
        guard let marker = candidate.first, marker == "`" || marker == "~" else { return nil }
        let count = candidate.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let suffix = candidate.dropFirst(count)
        guard marker != "`" || !suffix.contains("`") else { return nil }
        return (marker, count)
    }

    private static func isClosingFence(
        _ line: Substring,
        marker: Character,
        minimumCount: Int) -> Bool
    {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return false }
        let candidate = line.dropFirst(leadingSpaces)
        let count = candidate.prefix(while: { $0 == marker }).count
        return count >= minimumCount && candidate.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    private static func removingInlineCode(from line: String) -> String {
        let pattern = #"(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
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
