import Foundation
import Testing

struct TurkishLocalizationCoverageTests {
    @Test
    func `turkish localization keys and placeholders match english`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let enURL = root.appendingPathComponent("Sources/CodexBar/Resources/en.lproj/Localizable.strings")
        let trURL = root.appendingPathComponent("Sources/CodexBar/Resources/tr.lproj/Localizable.strings")

        let en = try Self.parseStrings(from: enURL)
        let tr = try Self.parseStrings(from: trURL)

        let missing = en.keys.filter { tr[$0] == nil }.sorted()
        let extra = tr.keys.filter { en[$0] == nil }.sorted()
        #expect(missing.isEmpty, "Missing Turkish keys: \(missing)")
        #expect(extra.isEmpty, "Extra Turkish keys: \(extra)")

        var placeholderMismatches: [String] = []
        for key in en.keys.sorted() {
            guard let trValue = tr[key] else { continue }
            if Self.placeholders(in: en[key] ?? "") != Self.placeholders(in: trValue) {
                placeholderMismatches.append(key)
            }
        }
        #expect(
            placeholderMismatches.isEmpty,
            "Turkish placeholder mismatches: \(placeholderMismatches)")
    }

    private static func parseStrings(from url: URL) throws -> [String: String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        let pattern = #"^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";\s*$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: content, options: [], range: range) {
            guard match.numberOfRanges == 3 else { continue }
            let key = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))
            result[key] = value
        }
        return result
    }

    private static func placeholders(in value: String) -> [String] {
        let pattern = #"(\\\([^)]*\)|%\d*\$?[sd@]|%@|%d|%f|\\n|\\u\{[0-9a-fA-F]+\})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = value as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: value, range: range).map { ns.substring(with: $0.range(at: 1)) }
    }
}
