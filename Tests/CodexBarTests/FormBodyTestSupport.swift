import Foundation
import Testing

enum FormBodyTestSupport {
    static func decode(_ data: Data) throws -> [String: String] {
        var fields: [String: String] = [:]
        let text = try #require(String(data: data, encoding: .utf8))
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            #expect(parts.count == 2)
            guard parts.count == 2 else { continue }
            let key = try #require(String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            let value = try #require(String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            #expect(fields.updateValue(value, forKey: key) == nil)
        }
        return fields
    }
}
