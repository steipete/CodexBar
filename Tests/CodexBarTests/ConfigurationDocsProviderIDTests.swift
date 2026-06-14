import CodexBarCore
import Foundation
import Testing

struct ConfigurationDocsProviderIDTests {
    @Test
    func `configuration docs list every provider id in enum order`() throws {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let docsURL = rootURL.appendingPathComponent("docs/configuration.md")
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
}
