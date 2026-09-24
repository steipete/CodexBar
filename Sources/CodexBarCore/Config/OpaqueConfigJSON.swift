import Foundation

/// Locates provider records without interpreting their numbers. JSONDecoder still validates the document.
enum OpaqueConfigJSON {
    /// Decoder integer coercion can round fractional tokens too. Inspect spelling before any typed promotion.
    static func hasExactIntegerTokens(in data: Data) -> Bool {
        var scanner = Scanner(bytes: Array(data))
        while let byte = scanner.current {
            if byte == 34 {
                guard (try? scanner.string()) != nil else { return false }
            } else if byte == 45 || (48...57).contains(byte) {
                guard let range = try? scanner.value(),
                      let token = String(bytes: scanner.bytes[range], encoding: .utf8),
                      let integer = Int64(token), String(integer) == token
                else { return false }
            } else {
                scanner.index += 1
            }
        }
        return true
    }

    static func providers(in data: Data) throws -> (range: Range<Int>, entries: [Range<Int>]) {
        var scanner = Scanner(bytes: Array(data))
        if scanner.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { scanner.index = 3 }
        try scanner.consume(123)
        var array: Range<Int>?
        while scanner.current != 125 {
            let key = try JSONDecoder().decode(String.self, from: data.subdata(in: scanner.value()))
            try scanner.consume(58)
            let value = try scanner.value()
            if key == "providers" {
                guard array == nil else { throw CocoaError(.coderReadCorrupt) }
                array = value
            }
            if scanner.current != 44 { break }
            try scanner.consume(44)
        }
        try scanner.consume(125)
        guard let array else { throw CocoaError(.coderReadCorrupt) }
        scanner.index = array.lowerBound
        try scanner.consume(91)
        var entries: [Range<Int>] = []
        while scanner.current != 93 {
            try entries.append(scanner.value())
            if scanner.current != 44 { break }
            try scanner.consume(44)
        }
        try scanner.consume(93)
        return (array, entries)
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        var current: UInt8? {
            mutating get {
                while self.index < self.bytes.count, [9, 10, 13, 32].contains(self.bytes[self.index]) {
                    self.index += 1
                }
                return self.index < self.bytes.count ? self.bytes[self.index] : nil
            }
        }

        mutating func consume(_ byte: UInt8) throws {
            guard self.current == byte else { throw CocoaError(.coderReadCorrupt) }
            self.index += 1
        }

        mutating func string() throws {
            try self.consume(34)
            while self.index < self.bytes.count {
                let byte = self.bytes[self.index]
                self.index += 1
                if byte == 34 { return }
                if byte == 92 { self.index += 1 }
            }
            throw CocoaError(.coderReadCorrupt)
        }

        mutating func value() throws -> Range<Int> {
            guard let first = self.current else { throw CocoaError(.coderReadCorrupt) }
            let start = self.index
            if first == 34 {
                try self.string()
            } else if first == 91 || first == 123 {
                var depth = 0
                repeat {
                    guard let byte = self.current else { throw CocoaError(.coderReadCorrupt) }
                    if byte == 34 {
                        try self.string()
                        continue
                    }
                    if byte == 91 || byte == 123 { depth += 1 }
                    if byte == 93 || byte == 125 { depth -= 1 }
                    self.index += 1
                } while depth > 0
            } else {
                while self.index < self.bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(self.bytes[self.index]) {
                    self.index += 1
                }
            }
            guard self.index > start else { throw CocoaError(.coderReadCorrupt) }
            return start..<self.index
        }
    }
}
