import Foundation
import Testing
@testable import CodexBar

struct AcknowledgementsTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let licenseDirectory = repoRoot.appendingPathComponent("Sources/CodexBar/Resources/Acknowledgements")

    private struct ResolvedPackages: Decodable {
        struct Pin: Decodable {
            let location: String
        }

        let pins: [Pin]
    }

    @Test
    func `bundled acknowledgements decode with license text`() {
        let acknowledgements = Acknowledgement.load()

        #expect(!acknowledgements.isEmpty)
        #expect(Set(acknowledgements.map(\.name)).count == acknowledgements.count)
        for acknowledgement in acknowledgements {
            #expect(acknowledgement.text.count > 200, "\(acknowledgement.name)")
            #expect(!acknowledgement.authors.isEmpty, "\(acknowledgement.name)")
            #expect(URL(string: acknowledgement.url)?.scheme == "https", "\(acknowledgement.name)")
        }
    }

    @Test
    func `every resolved package is acknowledged`() throws {
        let urls = Set(Acknowledgement.load().map(\.url))

        for pin in try Self.resolvedPins() {
            let url = Self.packageURL(pin)
            #expect(
                urls.contains(url),
                "\(url) needs an entry in Acknowledgements.json and a license in Resources/Acknowledgements")
        }
    }

    @Test
    func `every license file has an entry and every entry has a license file`() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.licenseDirectory.path)
            .filter { $0.hasSuffix(".txt") }
            .map { String($0.dropLast(4)) }

        #expect(Set(files) == Set(Acknowledgement.load().map(\.name)))
    }

    @Test
    func `license label matches the license text`() {
        for acknowledgement in Acknowledgement.load() {
            switch acknowledgement.license {
            case "MIT":
                #expect(
                    acknowledgement.text.contains("Permission is hereby granted, free of charge"),
                    "\(acknowledgement.name) is labeled MIT but its text is not")
            case "Apache-2.0":
                #expect(
                    acknowledgement.text.contains("Apache License") && acknowledgement.text.contains("Version 2.0"),
                    "\(acknowledgement.name) is labeled Apache-2.0 but its text is not")
            default:
                Issue.record("\(acknowledgement.name) has unknown license label \(acknowledgement.license)")
            }
        }
    }

    @Test
    func `listed authors appear in the license text`() {
        for acknowledgement in Acknowledgement.load() {
            for author in acknowledgement.authors {
                #expect(
                    acknowledgement.text.localizedCaseInsensitiveContains(author),
                    "\(author) is not in the \(acknowledgement.name) license")
            }
        }
    }

    /// Bundled texts must stay verbatim copies of the resolved checkouts' LICENSE (preceded by NOTICE, when present).
    /// Fails after a dependency bump changes its license; copy the new file into Resources/Acknowledgements.
    @Test
    func `bundled licenses match the resolved package checkouts`() throws {
        let checkouts = Self.repoRoot.appendingPathComponent(".build/checkouts")
        guard FileManager.default.fileExists(atPath: checkouts.path) else { return }
        let byURL = Dictionary(uniqueKeysWithValues: Acknowledgement.load().map { ($0.url, $0) })

        for pin in try Self.resolvedPins() {
            let url = Self.packageURL(pin)
            let checkout = checkouts.appendingPathComponent(URL(string: url)?.lastPathComponent ?? "")
            guard let license = Self.readFile(in: checkout, matching: ["license", "license.txt", "license.md"]),
                  let acknowledgement = byURL[url]
            else { continue }
            let notice = Self.readFile(in: checkout, matching: ["notice", "notice.txt", "notice.md"])
            let expected = [notice, license].compactMap(\.self).map(Self.normalized).joined(separator: "\n\n")
            #expect(Self.normalized(acknowledgement.text) == expected, "\(acknowledgement.name) license drifted")
        }
    }

    @Test
    func `vendored components are acknowledged with their licenses`() throws {
        let byName = Dictionary(uniqueKeysWithValues: Acknowledgement.load().map { ($0.name, $0) })

        let quickJS = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/CQuickJS/LICENSE"),
            encoding: .utf8)
        #expect(byName["QuickJS"].map { Self.normalized($0.text) } == Self.normalized(quickJS))

        let plugins = Self.repoRoot.appendingPathComponent("Sources/CodexBarCore/Resources/Plugins")
        let sucraseBundle = try #require(
            FileManager.default.contentsOfDirectory(atPath: plugins.path).first { $0.hasPrefix("sucrase-") })
        let banner = try String(contentsOf: plugins.appendingPathComponent(sucraseBundle), encoding: .utf8)
            .prefix(200)
        #expect(banner.contains("MIT License"))
        #expect(byName["Sucrase"]?.license == "MIT")
    }

    @Test
    func `author summary names two then counts the rest`() {
        let english = Locale(identifier: "en_US")
        let names = ["Ada", "Ben", "Cy", "Dee", "Eve", "Fay", "Gus"]

        let many = Self.acknowledgement(authors: names).authorSummary(locale: english)
        #expect(many.hasPrefix("Ada, Ben, and "))
        #expect(many.contains("5"))
        #expect(!many.contains("Cy"))

        let three = Self.acknowledgement(authors: Array(names.prefix(3))).authorSummary(locale: english)
        #expect(three == "Ada, Ben, and Cy")
        #expect(Self.acknowledgement(authors: ["Ada"]).authorSummary(locale: english) == "Ada")
    }

    private static func acknowledgement(authors: [String]) -> Acknowledgement {
        Acknowledgement(name: "Example", authors: authors, url: "https://example.com", license: "MIT", text: "")
    }

    private static func resolvedPins() throws -> [ResolvedPackages.Pin] {
        let data = try Data(contentsOf: self.repoRoot.appendingPathComponent("Package.resolved"))
        return try JSONDecoder().decode(ResolvedPackages.self, from: data).pins
    }

    private static func packageURL(_ pin: ResolvedPackages.Pin) -> String {
        pin.location.replacingOccurrences(of: ".git", with: "", options: .anchored.union(.backwards))
    }

    private static func readFile(in directory: URL, matching names: Set<String>) -> String? {
        let match = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .first { names.contains($0.lowercased()) }
        return match.flatMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
