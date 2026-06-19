import Foundation

extension CostUsageScanner {
    static func extractJSONByteStringField(
        _ field: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>,
        atDepth targetDepth: Int) -> String?
    {
        self.extractJSONByteField(field, from: bytes, in: range, atDepth: targetDepth) { valueIndex in
            guard let parsed = parseJSONByteStringRange(in: bytes, index: &valueIndex, limit: range.upperBound),
                  parsed.range.lowerBound < parsed.range.upperBound
            else { return nil }
            if parsed.hasEscapes {
                return self.decodeEscapedJSONByteString(from: bytes, in: parsed.range)
            }
            return String(bytes: bytes[parsed.range], encoding: .utf8)
        }
    }

    static func extractJSONByteObjectField(
        _ field: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>,
        atDepth targetDepth: Int) -> Range<Int>?
    {
        self.extractJSONByteField(field, from: bytes, in: range, atDepth: targetDepth) { valueIndex in
            self.parseJSONByteObjectRange(in: bytes, index: &valueIndex, limit: range.upperBound)
        }
    }

    static func extractJSONByteIntField(
        _ field: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>,
        atDepth targetDepth: Int) -> Int?
    {
        self.extractJSONByteField(field, from: bytes, in: range, atDepth: targetDepth) { valueIndex in
            self.parseJSONByteInt(in: bytes, index: &valueIndex, limit: range.upperBound)
        }
    }

    private static func extractJSONByteField<T>(
        _ field: [UInt8],
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>,
        atDepth targetDepth: Int,
        parseValue: (inout Int) -> T?) -> T?
    {
        var index = range.lowerBound
        var depth = 0

        while index < range.upperBound {
            switch bytes[index] {
            case 0x7B: // {
                depth += 1
                index += 1
            case 0x7D: // }
                depth -= 1
                index += 1
            case 0x22: // "
                var valueIndex = index
                guard let key = parseJSONByteStringRange(in: bytes, index: &valueIndex, limit: range.upperBound)
                else { return nil }
                index = valueIndex
                guard depth == targetDepth,
                      !key.hasEscapes,
                      self.byteRange(bytes, key.range, equals: field)
                else { continue }

                self.skipJSONByteWhitespace(in: bytes, index: &valueIndex, limit: range.upperBound)
                guard valueIndex < range.upperBound, bytes[valueIndex] == 0x3A else { continue } // :

                valueIndex += 1
                self.skipJSONByteWhitespace(in: bytes, index: &valueIndex, limit: range.upperBound)
                if let value = parseValue(&valueIndex) {
                    return value
                }
            default:
                index += 1
            }
        }

        return nil
    }

    private static func parseJSONByteStringRange(
        in bytes: UnsafeBufferPointer<UInt8>,
        index: inout Int,
        limit: Int) -> (range: Range<Int>, hasEscapes: Bool)?
    {
        guard index < limit, bytes[index] == 0x22 else { return nil } // "
        index += 1
        let start = index
        var hasEscapes = false

        while index < limit {
            switch bytes[index] {
            case 0x5C: // \
                hasEscapes = true
                index += 2
            case 0x22: // "
                let end = index
                index += 1
                return (start..<end, hasEscapes)
            default:
                index += 1
            }
        }

        return nil
    }

    private static func parseJSONByteObjectRange(
        in bytes: UnsafeBufferPointer<UInt8>,
        index: inout Int,
        limit: Int) -> Range<Int>?
    {
        guard index < limit, bytes[index] == 0x7B else { return nil } // {
        let start = index
        var depth = 0

        while index < limit {
            switch bytes[index] {
            case 0x22: // "
                guard self.parseJSONByteStringRange(in: bytes, index: &index, limit: limit) != nil else {
                    return nil
                }
            case 0x7B: // {
                depth += 1
                index += 1
            case 0x7D: // }
                depth -= 1
                index += 1
                if depth == 0 {
                    return start..<index
                }
            default:
                index += 1
            }
        }

        return nil
    }

    private static func parseJSONByteInt(
        in bytes: UnsafeBufferPointer<UInt8>,
        index: inout Int,
        limit: Int) -> Int?
    {
        var sign = 1
        if index < limit, bytes[index] == 0x2D { // -
            sign = -1
            index += 1
        }

        var value = 0
        var sawDigit = false
        while index < limit {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            let digit = Int(byte - 0x30)
            let multiplied = value.multipliedReportingOverflow(by: 10)
            if multiplied.overflow { return nil }
            let added = multiplied.partialValue.addingReportingOverflow(digit)
            if added.overflow { return nil }
            value = added.partialValue
            index += 1
        }
        return sawDigit ? (sign == -1 ? -value : value) : nil
    }

    private static func skipJSONByteWhitespace(
        in bytes: UnsafeBufferPointer<UInt8>,
        index: inout Int,
        limit: Int)
    {
        while index < limit {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    private static func decodeEscapedJSONByteString(
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>) -> String?
    {
        var out: [UInt8] = []
        out.reserveCapacity(range.count)
        var index = range.lowerBound
        while index < range.upperBound {
            let byte = bytes[index]
            guard byte == 0x5C else { // \
                out.append(byte)
                index += 1
                continue
            }

            index += 1
            guard index < range.upperBound else { return nil }
            switch bytes[index] {
            case 0x22, 0x5C, 0x2F: // ", \, /
                out.append(bytes[index])
            case 0x62: // b
                out.append(0x08)
            case 0x66: // f
                out.append(0x0C)
            case 0x6E: // n
                out.append(0x0A)
            case 0x72: // r
                out.append(0x0D)
            case 0x74: // t
                out.append(0x09)
            case 0x75: // u
                return self.decodeJSONStringViaFoundation(from: bytes, in: range)
            default:
                return nil
            }
            index += 1
        }

        return String(bytes: out, encoding: .utf8)
    }

    private static func decodeJSONStringViaFoundation(
        from bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>) -> String?
    {
        var data = Data([0x22])
        data.append(UnsafeBufferPointer(rebasing: bytes[range]))
        data.append(0x22)
        return (try? JSONSerialization.jsonObject(with: data)) as? String
    }

    private static func byteRange(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>,
        equals field: [UInt8]) -> Bool
    {
        guard range.count == field.count else { return false }
        var index = range.lowerBound
        var fieldIndex = 0
        while index < range.upperBound {
            guard bytes[index] == field[fieldIndex] else { return false }
            index += 1
            fieldIndex += 1
        }
        return true
    }
}
