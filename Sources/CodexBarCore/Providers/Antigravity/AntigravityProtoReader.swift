import Foundation

/// Decodes only the independently recorded generation layout; no inferred opaque timestamps.
struct AntigravityProtoReader {
    private let bytes: ArraySlice<UInt8>
    private var offset: Int
    private(set) var isMalformed = false

    init(bytes: [UInt8]) {
        self.init(slice: bytes[...])
    }

    private init(slice: ArraySlice<UInt8>) {
        self.bytes = slice
        self.offset = slice.startIndex
    }

    struct ParsedUsage: Equatable, Sendable {
        var systemPrompt = 0
        var newInput = 0
        var cacheRead = 0
        var output = 0
        var reasoning = 0
        var responseID: String?
        fileprivate var botIdentifier = AuxiliaryIdentifier()

        var botID: String? {
            self.botIdentifier.value
        }
    }

    struct ParsedTurn: Equatable, Sendable {
        var usage: ParsedUsage?
        var timestampMs: Int64?
        var model: String?
        var label: String?
        var stepUUID: String?
    }

    private struct Timestamp {
        var seconds: UInt64?
        var nanos: UInt64 = 0

        func milliseconds() throws -> Int64? {
            guard let seconds else { return nil }
            guard seconds > 0, seconds <= 253_402_300_799, self.nanos <= 999_999_999,
                  let seconds = Int64(exactly: seconds), let nanos = Int64(exactly: self.nanos)
            else { throw AntigravityLocalReader.ScanFailure.invalid }
            return seconds * 1000 + nanos / 1_000_000
        }
    }

    struct Field {
        let number: Int
        let wire: Int
        let data: ArraySlice<UInt8>?
        let value: UInt64?

        func message() throws -> ArraySlice<UInt8> {
            guard self.wire == 2, let data else { throw AntigravityLocalReader.ScanFailure.invalid }
            return data
        }

        func integer() throws -> UInt64 {
            guard self.wire == 0, let value else { throw AntigravityLocalReader.ScanFailure.invalid }
            return value
        }

        func counter() throws -> Int {
            guard let value = try Int(exactly: self.integer()) else {
                throw AntigravityLocalReader.ScanFailure.invalid
            }
            return value
        }

        func string() throws -> String? {
            guard let text = try String(bytes: self.message(), encoding: .utf8) else {
                throw AntigravityLocalReader.ScanFailure.invalid
            }
            // Preserve raw identities for conflict detection; whitespace-only optional fields are absent.
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }

    fileprivate struct AuxiliaryIdentifier: Equatable, Sendable {
        private(set) var value: String?
        private var isValid = true

        static func == (lhs: Self, rhs: Self) -> Bool {
            // Parser invalidity is not part of finalized event identity or copied-row deduplication.
            lhs.value == rhs.value
        }

        mutating func read(_ field: Field) throws {
            do {
                let value = try field.string()
                if self.isValid {
                    self.value = value
                }
            } catch AntigravityLocalReader.ScanFailure.invalid {
                self.invalidate()
            }
        }

        mutating func invalidate() {
            self.value = nil
            self.isValid = false
        }
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard self.offset < self.bytes.endIndex else { break }
            let byte = self.bytes[self.offset]
            self.offset += 1
            if index == 9, byte > 1 {
                break
            }
            result |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 {
                return result
            }
        }
        self.isMalformed = true
        return nil
    }

    mutating func nextField() -> Field? {
        guard self.offset < self.bytes.endIndex else { return nil }
        guard let tag = self.readVarint(), tag >> 3 > 0, tag >> 3 <= 536_870_911 else {
            self.isMalformed = true
            return nil
        }
        let number = Int(tag >> 3)
        let wire = Int(tag & 7)
        if wire == 0 {
            guard let value = self.readVarint() else { return nil }
            return Field(number: number, wire: wire, data: nil, value: value)
        }
        let count: Int? = switch wire {
        case 1: 8
        case 2: self.readVarint().flatMap(Int.init(exactly:))
        case 5: 4
        default: nil
        }
        guard let count, count <= self.bytes.endIndex - self.offset else {
            self.isMalformed = true
            return nil
        }
        let end = self.offset + count
        let data = self.bytes[self.offset..<end]
        self.offset = end
        return Field(number: number, wire: wire, data: data, value: nil)
    }

    private static func fields(
        _ bytes: ArraySlice<UInt8>,
        checkCancellation: () throws -> Void,
        visit: (Field) throws -> Void) throws
    {
        var reader = Self(slice: bytes)
        while reader.offset < reader.bytes.endIndex {
            try checkCancellation()
            guard let field = reader.nextField() else { break }
            try visit(field)
        }
        guard !reader.isMalformed else { throw AntigravityLocalReader.ScanFailure.invalid }
    }

    static func parseTurn(
        _ rootBytes: [UInt8],
        checkCancellation: () throws -> Void = {}) throws -> ParsedTurn?
    {
        var turn = ParsedTurn()
        var time = Timestamp()
        var foundChat = false
        do {
            // Repeated singular messages merge, scalars use last-one-wins. Every occurrence is validated.
            try self.fields(rootBytes[...], checkCancellation: checkCancellation) { field in
                switch field.number {
                case 1:
                    foundChat = true
                    try self.parseChat(
                        field.message(), turn: &turn, time: &time, checkCancellation: checkCancellation)
                case 4:
                    turn.stepUUID = try field.string()
                default:
                    break
                }
            }
            guard foundChat else { return nil }
            turn.timestampMs = try time.milliseconds()
            return turn
        } catch AntigravityLocalReader.ScanFailure.invalid {
            return nil
        }
    }

    struct StepMetadata: Equatable, Sendable {
        var stepUUID: String?
        var botID: String?
        var timestampMs: Int64?
    }

    static func parseStepMetadata(
        _ bytes: [UInt8],
        checkCancellation: () throws -> Void = {}) throws -> StepMetadata?
    {
        var stepUUID: String?
        var botIdentifier = AuxiliaryIdentifier()
        var time = Timestamp()
        var timestampIsValid = true
        do {
            try self.fields(bytes[...], checkCancellation: checkCancellation) { field in
                switch field.number {
                case 1:
                    do {
                        try self.parseTimestampField(
                            field.message(), time: &time, checkCancellation: checkCancellation)
                    } catch AntigravityLocalReader.ScanFailure.invalid {
                        timestampIsValid = false
                    }
                case 9:
                    // Malformed auxiliary IDs disable exact matching, even if a later envelope is valid.
                    do {
                        try self.fields(field.message(), checkCancellation: checkCancellation) { subfield in
                            if subfield.number == 7 {
                                try botIdentifier.read(subfield)
                            }
                        }
                    } catch AntigravityLocalReader.ScanFailure.invalid {
                        botIdentifier.invalidate()
                    }
                case 12:
                    stepUUID = try field.string()
                default:
                    break
                }
            }
            let ms = timestampIsValid ? try time.milliseconds() : nil
            return StepMetadata(stepUUID: stepUUID, botID: botIdentifier.value, timestampMs: ms)
        } catch AntigravityLocalReader.ScanFailure.invalid {
            return nil
        }
    }

    private static func parseChat(
        _ bytes: ArraySlice<UInt8>,
        turn: inout ParsedTurn,
        time: inout Timestamp,
        checkCancellation: () throws -> Void) throws
    {
        try self.fields(bytes, checkCancellation: checkCancellation) { field in
            switch field.number {
            case 4:
                var usage = turn.usage ?? ParsedUsage()
                try self.parseUsage(field.message(), usage: &usage, checkCancellation: checkCancellation)
                turn.usage = usage
            case 9:
                try self.parseGeneration(field.message(), time: &time, checkCancellation: checkCancellation)
            case 19: turn.model = try field.string()
            case 21: turn.label = try field.string()
            default: break
            }
        }
    }

    private static func parseUsage(
        _ bytes: ArraySlice<UInt8>,
        usage: inout ParsedUsage,
        checkCancellation: () throws -> Void) throws
    {
        try self.fields(bytes, checkCancellation: checkCancellation) { field in
            switch field.number {
            case 1: usage.systemPrompt = try field.counter()
            case 2: usage.newInput = try field.counter()
            case 5: usage.cacheRead = try field.counter()
            case 7: try usage.botIdentifier.read(field)
            case 9: usage.output = try field.counter()
            case 10: usage.reasoning = try field.counter()
            case 11: usage.responseID = try field.string()
            default: break
            }
        }
    }

    private static func parseTimestampField(
        _ bytes: ArraySlice<UInt8>,
        time: inout Timestamp,
        checkCancellation: () throws -> Void) throws
    {
        try self.fields(bytes, checkCancellation: checkCancellation) { stamp in
            switch stamp.number {
            case 1:
                let seconds = try stamp.integer()
                guard seconds > 0, seconds <= 253_402_300_799 else {
                    throw AntigravityLocalReader.ScanFailure.invalid
                }
                time.seconds = seconds
            case 2:
                let nanos = try stamp.integer()
                guard nanos <= 999_999_999 else { throw AntigravityLocalReader.ScanFailure.invalid }
                time.nanos = nanos
            default: break
            }
        }
    }

    private static func parseGeneration(
        _ bytes: ArraySlice<UInt8>,
        time: inout Timestamp,
        checkCancellation: () throws -> Void) throws
    {
        try self.fields(bytes, checkCancellation: checkCancellation) { field in
            guard field.number == 4 else { return }
            try self.parseTimestampField(field.message(), time: &time, checkCancellation: checkCancellation)
        }
    }
}
