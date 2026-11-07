import Foundation

/// Preserve number lexemes before Foundation can round them. Foundation still validates JSON structure and strings.
enum LosslessJSONLObject {
    struct Number {
        let integer: Int?
    }

    struct Decoded {
        let object: Any
        let numbers: [[String]: [String: Number]]
        let hasDuplicateKeys: Bool
        let ordinaryCompatible: Bool
    }

    private enum Invalid: Error { case syntax }

    static func decode(
        _ bytes: [UInt8],
        numberObjectPaths: Set<[String]> = [[]],
        preserveOrdinaryNumbers: Bool = false,
        checkCancellation: @escaping () throws -> Void) throws -> Decoded?
    {
        do {
            var lexer = Lexer(
                bytes: bytes,
                masked: bytes,
                numberObjectPaths: numberObjectPaths,
                preserveOrdinaryNumbers: preserveOrdinaryNumbers,
                checkCancellation: checkCancellation)
            return try lexer.object()
        } catch Invalid.syntax {
            return nil
        }
    }

    private static func foundationValue(_ bytes: ArraySlice<UInt8>) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
        } catch {
            throw Invalid.syntax
        }
    }

    /// Unescaped keys are their raw bytes. Invalid UTF-8 or raw controls still fail full-line validation.
    private static func key(_ token: ArraySlice<UInt8>) throws -> String {
        // swiftlint:disable:next optional_data_string_conversion
        guard token.contains(92) else { return String(decoding: token.dropFirst().dropLast(), as: UTF8.self) }
        guard let key = try foundationValue(token) as? String else { throw Invalid.syntax }
        return key
    }

    private struct Lexer {
        let bytes: [UInt8]
        var masked: [UInt8]
        let numberObjectPaths: Set<[String]>
        let preserveOrdinaryNumbers: Bool
        let checkCancellation: () throws -> Void
        var index = 0

        private struct Frame {
            let path: [String]?
            let isObject: Bool
            var key: String?
            var expectingKey = true
            var keys = Set<String>()
        }

        mutating func object() throws -> Decoded {
            var frames: [Frame] = []
            var numbers: [[String]: [String: Number]] = [:]
            var hasDuplicateKeys = false
            var ordinaryCompatible = true
            while let byte = self.current {
                switch byte {
                case 34:
                    let start = self.index
                    try self.string()
                    if var frame = frames.last, frame.isObject, frame.expectingKey, let path = frame.path,
                       self.numberObjectPaths.contains(where: { $0.starts(with: path) })
                    {
                        let name = try LosslessJSONLObject.key(self.bytes[start..<self.index])
                        if let path = frame.path, self.numberObjectPaths.contains(path),
                           !frame.keys.insert(name).inserted { hasDuplicateKeys = true }
                        frame.key = name
                        frame.expectingKey = false
                        frames[frames.count - 1] = frame
                    }
                case 123, 91:
                    let path: [String]? = if frames.isEmpty {
                        []
                    } else if let parent = frames.last, parent.isObject, let parentPath = parent.path,
                              let key = parent.key
                    {
                        parentPath + [key]
                    } else {
                        nil
                    }
                    frames.append(Frame(path: path, isObject: byte == 123))
                    guard frames.count <= 512 else { throw Invalid.syntax }
                    try self.advance()
                case 125, 93:
                    guard !frames.isEmpty else { throw Invalid.syntax }
                    frames.removeLast()
                    try self.advance()
                case 44:
                    if !frames.isEmpty {
                        frames[frames.count - 1].key = nil
                        frames[frames.count - 1].expectingKey = true
                    }
                    try self.advance()
                case 45, 48...57:
                    let start = self.index
                    let value = try self.number()
                    if let frame = frames.last, frame.isObject, let path = frame.path,
                       self.numberObjectPaths.contains(path), let key = frame.key
                    {
                        numbers[path, default: [:]][key] = Number(integer: value)
                    }
                    // Ordinary consumers keep Foundation's selected numeric scalars. Mask overflow only
                    // so strict consumers can still quarantine its otherwise valid request identity.
                    // The lexer has already validated these ASCII numeric bytes.
                    // swiftlint:disable:next optional_data_string_conversion
                    let finite = Double(String(decoding: self.bytes[start..<self.index], as: UTF8.self))?
                        .isFinite == true
                    ordinaryCompatible = ordinaryCompatible && finite
                    if self.preserveOrdinaryNumbers, finite { continue }
                    self.masked[start] = 48
                    for offset in (start + 1)..<self.index {
                        if offset % 4096 == 0 { try self.checkCancellation() }
                        self.masked[offset] = 32
                    }
                default: try self.advance()
                }
            }
            try self.checkCancellation()
            let object = try LosslessJSONLObject.foundationValue(self.masked[...])
            return Decoded(
                object: object,
                numbers: numbers,
                hasDuplicateKeys: hasDuplicateKeys,
                ordinaryCompatible: ordinaryCompatible)
        }

        private var current: UInt8? {
            self.index < self.bytes.count ? self.bytes[self.index] : nil
        }

        private var isDigit: Bool {
            self.current.map { (48...57).contains($0) } ?? false
        }

        private mutating func advance() throws {
            if self.index % 4096 == 0 { try self.checkCancellation() }
            self.index += 1
        }

        private mutating func string() throws {
            try self.advance()
            while let byte = self.current {
                try self.advance()
                if byte == 34 { return }
                if byte == 92 {
                    guard self.current != nil else { throw Invalid.syntax }
                    try self.advance()
                }
            }
            throw Invalid.syntax
        }

        private mutating func number() throws -> Int? {
            let negative = self.current == 45
            if negative { try self.advance() }
            guard self.isDigit else { throw Invalid.syntax }
            var digits: [UInt8] = []
            var significantCount = 0
            var trailingZeros = 0
            func record(_ byte: UInt8) {
                guard byte != 48 || significantCount > 0 else { return }
                significantCount += 1
                trailingZeros = byte == 48 ? trailingZeros + 1 : 0
                if digits.count < 19 { digits.append(byte - 48) }
            }
            if self.current == 48 {
                try self.advance()
                guard !self.isDigit else { throw Invalid.syntax }
            } else {
                while self.isDigit {
                    record(self.bytes[self.index])
                    try self.advance()
                }
            }
            var fractionDigits = 0
            if self.current == 46 {
                try self.advance()
                guard self.isDigit else { throw Invalid.syntax }
                while self.isDigit {
                    record(self.bytes[self.index])
                    fractionDigits += 1
                    try self.advance()
                }
            }
            var exponent = 0
            if self.current == 69 || self.current == 101 {
                try self.advance()
                let negativeExponent = self.current == 45
                if self.current == 43 || negativeExponent { try self.advance() }
                guard self.isDigit else { throw Invalid.syntax }
                while self.isDigit {
                    // A larger exponent cannot be cancelled by this bounded token's fractional digits.
                    exponent = min(exponent * 10 + Int(self.bytes[self.index] - 48), self.bytes.count + 20)
                    try self.advance()
                }
                if negativeExponent { exponent = -exponent }
            }
            if significantCount == 0 { return 0 }
            let count = significantCount - trailingZeros
            let power = exponent - fractionDigits + trailingZeros
            guard !negative, power >= 0, count + power <= 19 else { return nil }
            var value = 0
            for index in 0..<(count + power) {
                let digit = index < count ? digits[index] : 0
                let (product, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
                let (sum, addOverflow) = product.addingReportingOverflow(Int(digit))
                guard !multiplyOverflow, !addOverflow else { return nil }
                value = sum
            }
            return value
        }
    }
}
