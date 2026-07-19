import Foundation

enum CostUsageJsonl {
    struct Line {
        let bytes: Data
        let wasTruncated: Bool
    }

    private struct JSONTailState {
        private enum ScalarState {
            case notScalar
            case trueLiteral(Int)
            case falseLiteral(Int)
            case nullLiteral(Int)
            case number(NumberState)
            case invalid
        }

        private enum NumberState {
            private enum ByteKind {
                case zero
                case digit
                case decimalPoint
                case exponentMarker
                case sign
                case whitespace
                case other

                init(_ byte: UInt8) {
                    switch byte {
                    case 0x30: self = .zero
                    case 0x31...0x39: self = .digit
                    case 0x2E: self = .decimalPoint
                    case 0x65, 0x45: self = .exponentMarker
                    case 0x2B, 0x2D: self = .sign
                    case 0x20, 0x09, 0x0A, 0x0D: self = .whitespace
                    default: self = .other
                    }
                }
            }

            case sign
            case zero
            case integer
            case decimalPoint
            case fraction
            case exponentMarker
            case exponentSign
            case exponentDigits
            case finished
            case invalid

            var canCommitAtEOF: Bool {
                switch self {
                case .finished, .invalid:
                    true
                case .sign, .zero, .integer, .decimalPoint, .fraction,
                     .exponentMarker, .exponentSign, .exponentDigits:
                    false
                }
            }

            func appending(_ byte: UInt8) -> Self {
                switch (self, ByteKind(byte)) {
                case (.invalid, _): .invalid
                case (.finished, .whitespace): .finished
                case (.sign, .zero): .zero
                case (.sign, .digit): .integer
                case (.zero, .decimalPoint): .decimalPoint
                case (.zero, .exponentMarker): .exponentMarker
                case (.integer, .zero), (.integer, .digit): .integer
                case (.integer, .decimalPoint): .decimalPoint
                case (.integer, .exponentMarker): .exponentMarker
                case (.decimalPoint, .zero), (.decimalPoint, .digit): .fraction
                case (.fraction, .zero), (.fraction, .digit): .fraction
                case (.fraction, .exponentMarker): .exponentMarker
                case (.exponentMarker, .sign): .exponentSign
                case (.exponentMarker, .zero), (.exponentMarker, .digit): .exponentDigits
                case (.exponentSign, .zero), (.exponentSign, .digit): .exponentDigits
                case (.exponentDigits, .zero), (.exponentDigits, .digit): .exponentDigits
                case (.zero, .whitespace),
                     (.integer, .whitespace),
                     (.fraction, .whitespace),
                     (.exponentDigits, .whitespace): .finished
                default: .invalid
                }
            }
        }

        private static let trueLiteral = Array("true".utf8)
        private static let falseLiteral = Array("false".utf8)
        private static let nullLiteral = Array("null".utf8)

        private var containerDepth = 0
        private var insideString = false
        private var escaping = false
        private var sawNonWhitespace = false
        private var scalarState = ScalarState.notScalar

        mutating func reset() {
            self = Self()
        }

        var isStructurallyComplete: Bool {
            guard self.sawNonWhitespace else { return false }
            switch self.scalarState {
            case .notScalar:
                return !self.insideString && self.containerDepth == 0
            case let .trueLiteral(matched):
                return matched == Self.trueLiteral.count
            case let .falseLiteral(matched):
                return matched == Self.falseLiteral.count
            case let .nullLiteral(matched):
                return matched == Self.nullLiteral.count
            case let .number(state):
                return state.canCommitAtEOF
            case .invalid:
                return true
            }
        }

        mutating func append(_ byte: UInt8) {
            if !self.sawNonWhitespace {
                self.start(byte)
                return
            }

            guard !self.appendScalar(byte) else { return }
            self.appendContainer(byte)
        }

        private mutating func start(_ byte: UInt8) {
            guard !Self.isWhitespace(byte) else { return }
            self.sawNonWhitespace = true
            switch byte {
            case 0x22:
                self.insideString = true
            case 0x7B, 0x5B:
                self.containerDepth = 1
            case 0x74:
                self.scalarState = .trueLiteral(1)
            case 0x66:
                self.scalarState = .falseLiteral(1)
            case 0x6E:
                self.scalarState = .nullLiteral(1)
            case 0x2D:
                self.scalarState = .number(.sign)
            case 0x30:
                self.scalarState = .number(.zero)
            case 0x31...0x39:
                self.scalarState = .number(.integer)
            default:
                self.scalarState = .invalid
            }
        }

        private mutating func appendScalar(_ byte: UInt8) -> Bool {
            switch self.scalarState {
            case let .trueLiteral(matched):
                self.scalarState = self.advanceLiteral(byte, expected: Self.trueLiteral, matched: matched)
                    .map(ScalarState.trueLiteral) ?? .invalid
                return true
            case let .falseLiteral(matched):
                self.scalarState = self.advanceLiteral(byte, expected: Self.falseLiteral, matched: matched)
                    .map(ScalarState.falseLiteral) ?? .invalid
                return true
            case let .nullLiteral(matched):
                self.scalarState = self.advanceLiteral(byte, expected: Self.nullLiteral, matched: matched)
                    .map(ScalarState.nullLiteral) ?? .invalid
                return true
            case let .number(state):
                self.scalarState = .number(state.appending(byte))
                return true
            case .invalid:
                return true
            case .notScalar:
                return false
            }
        }

        private mutating func appendContainer(_ byte: UInt8) {
            if self.insideString {
                if self.escaping {
                    self.escaping = false
                } else if byte == 0x5C {
                    self.escaping = true
                } else if byte == 0x22 {
                    self.insideString = false
                }
                return
            }

            switch byte {
            case 0x20, 0x09, 0x0D:
                return
            case 0x22:
                self.insideString = true
            case 0x7B, 0x5B:
                self.containerDepth += 1
            case 0x7D, 0x5D:
                self.containerDepth = max(0, self.containerDepth - 1)
            default:
                break
            }
        }

        private func advanceLiteral(
            _ byte: UInt8,
            expected: [UInt8],
            matched: Int) -> Int?
        {
            if matched < expected.count {
                return byte == expected[matched] ? matched + 1 : nil
            }
            return Self.isWhitespace(byte) ? matched : nil
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        try self.scan(
            fileURL: fileURL,
            offset: offset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            checkCancellation: nil,
            onLine: onLine)
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        checkCancellation: (() throws -> Void)? = nil,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var truncated = false
        var bytesRead: Int64 = 0
        var committedOffset = startOffset
        var jsonTailState = JSONTailState()

        func appendSegment(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }
            lineBytes += count
            if current.count < prefixBytes {
                let appendCount = min(prefixBytes - current.count, count)
                if appendCount > 0 {
                    current.append(bytes, count: appendCount)
                }
            }
            if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                truncated = true
            }
        }

        func flushLine() {
            guard lineBytes > 0 else { return }
            let line = Line(bytes: current, wasTruncated: truncated)
            onLine(line)
            current.removeAll(keepingCapacity: true)
            lineBytes = 0
            truncated = false
            jsonTailState.reset()
        }

        func hasCompleteJSONTail() -> Bool {
            guard jsonTailState.isStructurallyComplete else { return false }
            if truncated {
                // The full record is intentionally not retained. Its incremental state is enough
                // to keep incomplete containers, strings, literals, and numbers retriable.
                return true
            }
            guard lineBytes == current.count else { return false }
            return (try? JSONSerialization.jsonObject(with: current, options: [.fragmentsAllowed])) != nil
        }

        while true {
            try checkCancellation?()
            let reachedEOF = try autoreleasepool {
                let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty {
                    if hasCompleteJSONTail() {
                        flushLine()
                        committedOffset = startOffset + bytesRead
                    }
                    return true
                }

                try checkCancellation?()
                bytesRead += Int64(chunk.count)
                let chunkStartOffset = startOffset + bytesRead - Int64(chunk.count)
                chunk.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    var segmentStart = 0
                    var index = 0
                    while index < rawBuffer.count {
                        if base[index] == 0x0A {
                            appendSegment(base.advanced(by: segmentStart), count: index - segmentStart)
                            flushLine()
                            committedOffset = chunkStartOffset + Int64(index + 1)
                            segmentStart = index + 1
                        } else {
                            jsonTailState.append(base[index])
                        }
                        index += 1
                    }
                    if segmentStart < rawBuffer.count {
                        appendSegment(base.advanced(by: segmentStart), count: rawBuffer.count - segmentStart)
                    }
                }
                return false
            }
            if reachedEOF {
                break
            }
            try checkCancellation?()
        }

        return committedOffset
    }
}
