import Foundation
import Testing
@testable import CodexBar

struct AcknowledgementsTests {
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
    func `bundled notices include nested licenses for every platform`() throws {
        let byName = Dictionary(uniqueKeysWithValues: Acknowledgement.load().map { ($0.name, $0) })
        #expect(try #require(byName["QuickJS"]).text.contains("UNICODE LICENSE V3"))
        #expect(try #require(byName["XKCP"]).text.contains("Brian Gladman"))
        #expect(try #require(byName["BoringSSL"]).text.contains("Apache License"))
        #expect(try #require(byName["@jridgewell/sourcemap-codec"]).text.contains("Permission is hereby granted"))
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

    @Test
    func `author summary follows the selected app language`() {
        let names = ["Ada", "Ben", "Cy", "Dee", "Eve", "Fay", "Gus"]

        CodexBarLocalizationOverride.$appLanguage.withValue("fr") {
            let summary = Self.acknowledgement(authors: names).authorSummary()
            #expect(summary.hasPrefix("Ada, Ben et "), "\(summary)")
            #expect(summary.hasSuffix("5 autres"), "\(summary)")
        }
    }

    private static func acknowledgement(authors: [String]) -> Acknowledgement {
        Acknowledgement(name: "Example", authors: authors, url: "https://example.com", license: "MIT", text: "")
    }
}
