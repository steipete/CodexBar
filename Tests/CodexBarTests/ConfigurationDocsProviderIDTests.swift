import CodexBarCore
import Foundation
import Testing

struct ConfigurationDocsProviderIDTests {
    @Test
    func `configuration docs list every provider id in enum order`() throws {
        let rootURL = try Self.repoRoot()
        let docsURL = rootURL.appending(path: "docs/configuration.md")
        let docs = try String(contentsOf: docsURL, encoding: .utf8)

        let marker = "## Provider IDs"
        let sectionStart = try #require(docs.range(of: marker)?.upperBound)
        let section = docs[sectionStart...]
        let idsLine = try #require(section.split(separator: "\n").first { $0.hasPrefix("`") })

        let documentedIDs = idsLine
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " `.")) }
        let expectedIDs = UsageProvider.allCases.map(\.rawValue)

        #expect(documentedIDs == expectedIDs)
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let packageManifest = directory.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: packageManifest.path(percentEncoded: false)) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "ConfigurationDocsProviderIDTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root (Package.swift) from \(#filePath)",
        ])
    }
}
