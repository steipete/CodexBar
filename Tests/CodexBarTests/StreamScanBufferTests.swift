import Foundation
import Testing
@testable import CodexBarCore

struct StreamScanBufferTests {
    @Test
    func `markers split across reads remain searchable with bounded overlap`() {
        let needle = Data("ready".utf8)
        for split in 1..<needle.count {
            var buffer = StreamScanBuffer(maxNeedle: needle.count)
            _ = buffer.append(Data(repeating: 0, count: 100) + needle.prefix(split))
            #expect(buffer.append(Data()).isEmpty)
            let scanned = buffer.append(needle.dropFirst(split))
            #expect(scanned.range(of: needle) != nil)
            #expect(scanned.count <= needle.count - 1 + needle.count - split)
            buffer.reset()
            #expect(buffer.append(Data("x".utf8)) == Data("x".utf8))
        }
    }

    @Test(arguments: [-1, 0, 1])
    func `single byte scans do not retain previous chunks`(maxNeedle: Int) {
        var buffer = StreamScanBuffer(maxNeedle: maxNeedle)
        _ = buffer.append(Data("first".utf8))
        #expect(buffer.append(Data("next".utf8)) == Data("next".utf8))
    }
}
