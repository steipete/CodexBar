import Foundation

/// Decodes raw (unframed) Snappy blocks, as used by Gecko's `ls/data.sqlite` local storage values.
enum SnappyBlockDecoder {
    /// Local-storage tokens are a few kilobytes. Reject anything larger before allocating.
    static let maximumOutputLength = 1 << 20

    static func decompress(_ data: Data) -> Data? {
        let input = [UInt8](data)
        var index = 0
        guard let expectedLength = self.readVarint(input, index: &index),
              expectedLength <= self.maximumOutputLength
        else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(expectedLength)

        while index < input.count {
            let tag = input[index]
            index += 1
            switch tag & 0x03 {
            case 0:
                var length = Int(tag >> 2)
                if length >= 60 {
                    let byteCount = length - 59
                    guard index + byteCount <= input.count else { return nil }
                    length = 0
                    for offset in 0..<byteCount {
                        length |= Int(input[index + offset]) << (8 * offset)
                    }
                    index += byteCount
                }
                length += 1
                guard index + length <= input.count, output.count + length <= expectedLength else { return nil }
                output.append(contentsOf: input[index..<(index + length)])
                index += length
            case 1:
                guard index < input.count else { return nil }
                let length = Int((tag >> 2) & 0x07) + 4
                let offset = (Int(tag >> 5) << 8) | Int(input[index])
                index += 1
                guard self.copy(length: length, offset: offset, into: &output, limit: expectedLength) else {
                    return nil
                }
            case 2:
                guard index + 2 <= input.count else { return nil }
                let length = Int(tag >> 2) + 1
                let offset = Int(input[index]) | (Int(input[index + 1]) << 8)
                index += 2
                guard self.copy(length: length, offset: offset, into: &output, limit: expectedLength) else {
                    return nil
                }
            default:
                guard index + 4 <= input.count else { return nil }
                let length = Int(tag >> 2) + 1
                var offset = 0
                for byte in 0..<4 {
                    offset |= Int(input[index + byte]) << (8 * byte)
                }
                index += 4
                guard self.copy(length: length, offset: offset, into: &output, limit: expectedLength) else {
                    return nil
                }
            }
        }

        return output.count == expectedLength ? Data(output) : nil
    }

    private static func readVarint(_ input: [UInt8], index: inout Int) -> Int? {
        var result = 0
        var shift = 0
        while index < input.count, shift <= 28 {
            let byte = input[index]
            index += 1
            result |= Int(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    private static func copy(length: Int, offset: Int, into output: inout [UInt8], limit: Int) -> Bool {
        guard offset > 0, offset <= output.count, output.count + length <= limit else { return false }
        let start = output.count - offset
        for position in 0..<length {
            output.append(output[start + position])
        }
        return true
    }
}
