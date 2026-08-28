import Foundation

/// Preserve number lexemes before Foundation can round them. Foundation still validates JSON structure and strings.
enum AntigravityJSONLObject {
    struct Number {
        let integer: Int?
    }

    private enum Invalid: Error { case syntax }

    static func decode(_ bytes: [UInt8], checkCancellation: @escaping () throws -> Void) throws -> [String: Any]? {
        do {
            var lexer = Lexer(bytes: bytes, masked: bytes, checkCancellation: checkCancellation)
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

    private struct Lexer {
        let bytes: [UInt8]
        var masked: [UInt8]
        let checkCancellation: () throws -> Void
        var index = 0

        mutating func object() throws -> [String: Any] {
            var depth = 0
            var key: String?
            var expectingKey = true
            var keys = Set<String>()
            var numbers: [String: Number] = [:]
            while let byte = self.current {
                switch byte {
                case 34:
                    let start = self.index
                    try self.string()
                    if depth == 1, expectingKey {
                        guard let name = try AntigravityJSONLObject.foundationValue(self.bytes[start..<self.index])
                            as? String,
                            keys.insert(name).inserted else { throw Invalid.syntax }
                        key = name
                        expectingKey = false
                    }
                case 123, 91:
                    depth += 1
                    guard depth <= 512 else { throw Invalid.syntax }
                    try self.advance()
                case 125, 93:
                    depth -= 1
                    guard depth >= 0 else { throw Invalid.syntax }
                    try self.advance()
                case 44:
                    if depth == 1 {
                        key = nil
                        expectingKey = true
                    }
                    try self.advance()
                case 45, 48...57:
                    let start = self.index
                    let value = try self.number()
                    if depth == 1, let key { numbers[key] = Number(integer: value) }
                    // Keep byte positions/JSON separators, replacing only a fully validated numeric token.
                    self.masked[start] = 48
                    for offset in (start + 1)..<self.index {
                        if offset % 4096 == 0 { try self.checkCancellation() }
                        self.masked[offset] = 32
                    }
                default: try self.advance()
                }
            }
            try self.checkCancellation()
            guard var object = try AntigravityJSONLObject.foundationValue(self.masked[...]) as? [String: Any] else {
                throw Invalid.syntax
            }
            for (index, entry) in numbers.enumerated() {
                if index % 256 == 0 { try self.checkCancellation() }
                object[entry.key] = entry.value
            }
            return object
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
