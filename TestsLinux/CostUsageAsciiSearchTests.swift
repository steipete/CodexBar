import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageAsciiSearchTests {
    @Test
    func `exact byte searches preserve Foundation results within data slice bounds`() {
        let cases: [(Data, String)] = [
            (Data(), ""),
            (Data(), "needle"),
            (Data("needle".utf8), ""),
            (Data("needle".utf8), "needle"),
            (Data("prefix needle".utf8), "needle"),
            (Data("needle".utf8), "needles"),
            (Data("needleneedle".utf8), "needle"),
            (Data("aaaaab".utf8), "aaab"),
            (Data("aaaaab".utf8), "aaac"),
            (Data([0, 255, 34, 0, 92]), "\0\\"),
            (Data("é🦞é".utf8), "🦞é"),
        ]
        let padding = Data("needle".utf8)
        for (bytes, needle) in cases {
            let padded = padding + bytes + padding
            for data in [bytes, padded.dropFirst(padding.count).dropLast(padding.count)] {
                #expect(data.containsAscii(needle) == (data.range(of: Data(needle.utf8)) != nil))
            }
        }
    }

    @Test
    func `safe integer and byte subscripts preserve bounds`() {
        let integers = [11, 12]
        let bytes: [UInt8] = [11, 12]
        #expect(integers[safe: -1] == nil)
        #expect(integers[safe: 2] == nil)
        #expect(integers[safe: 1] == 12)
        #expect(bytes[safe: -1] == nil)
        #expect(bytes[safe: 2] == nil)
        #expect(bytes[safe: 1] == 12)
    }
}
