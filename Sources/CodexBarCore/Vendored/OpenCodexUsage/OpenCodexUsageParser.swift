#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public enum OpenCodexUsageParser {
    private static let newline: UInt8 = 0x0A

    @TaskLocal static var logReadRecorderForTesting: LogReadRecorder?

    final class LogReadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bytesRead: Int64 = 0
        private var completeLines = 0

        func record(bytes: Int64, lines: Int) {
            self.lock.lock()
            self.bytesRead += bytes
            self.completeLines += lines
            self.lock.unlock()
        }

        func snapshot() -> (bytesRead: Int64, completeLines: Int) {
            self.lock.lock()
            defer { self.lock.unlock() }
            return (self.bytesRead, self.completeLines)
        }
    }

    static func withLogReadRecorderForTesting<T>(
        _ recorder: LogReadRecorder,
        operation: () throws -> T) rethrows -> T
    {
        try self.$logReadRecorderForTesting.withValue(recorder) {
            try operation()
        }
    }

    public static func parseLine(_ line: String) -> OpenCodexUsageEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return self.parse(data)
    }

    public static func parse(_ data: Data) -> OpenCodexUsageEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return self.parse(object)
    }

    public static func parseLines(_ text: String) -> [OpenCodexUsageEntry] {
        self.parseJSONL(Data(text.utf8), baseOffset: 0).entries
    }

    public static func parse(fileURL: URL, fileManager: FileManager = .default) throws -> [OpenCodexUsageEntry] {
        try self.parseLog(fileURL: fileURL, from: 0, fileManager: fileManager).entries
    }

    public static func parse(
        fileURL: URL,
        from offset: Int64,
        fileManager: FileManager = .default) throws -> (entries: [OpenCodexUsageEntry], nextOffset: Int64)
    {
        let parsed = try self.parseLog(fileURL: fileURL, from: offset, fileManager: fileManager)
        return (parsed.entries, parsed.nextOffset)
    }

    static func parseLog(
        fileURL: URL,
        from offset: Int64,
        fileManager: FileManager) throws -> JSONLParseResult
    {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return JSONLParseResult(
                entries: [],
                nextOffset: max(0, offset),
                bytesRead: 0,
                completeLineCount: 0,
                newlineTerminatedEntryCount: 0)
        }

        let startOffset = max(0, offset)
        let data: Data
        if startOffset == 0 {
            // `.mappedIfSafe` assumes the file is append-only; a shrink under an active mapping is
            // formally undefined.
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } else {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(startOffset))
            data = try handle.readToEnd() ?? Data()
        }

        let parsed = self.parseJSONL(data, baseOffset: startOffset)
        self.logReadRecorderForTesting?.record(bytes: parsed.bytesRead, lines: parsed.completeLineCount)
        return parsed
    }

    struct JSONLParseResult: Equatable, Sendable {
        var entries: [OpenCodexUsageEntry]
        var nextOffset: Int64
        var bytesRead: Int64
        var completeLineCount: Int
        var newlineTerminatedEntryCount: Int

        var newlineTerminatedEntries: [OpenCodexUsageEntry] {
            Array(self.entries.prefix(self.newlineTerminatedEntryCount))
        }

        var pendingTrailingEntries: [OpenCodexUsageEntry] {
            Array(self.entries.dropFirst(self.newlineTerminatedEntryCount))
        }
    }

    private static func parseJSONL(_ data: Data, baseOffset: Int64) -> JSONLParseResult {
        var entries: [OpenCodexUsageEntry] = []
        var completeLineCount = 0
        var lineStart = data.startIndex
        var lastCompleteEnd = data.startIndex
        for newlineOffset in self.newlineOffsets(in: data) {
            let newlineIndex = data.index(data.startIndex, offsetBy: newlineOffset)
            if let entry = self.parseLineData(data[lineStart..<newlineIndex]) {
                entries.append(entry)
            }
            completeLineCount += 1
            lastCompleteEnd = data.index(after: newlineIndex)
            lineStart = lastCompleteEnd
        }
        let newlineTerminatedEntryCount = entries.count
        // Keep emitting a complete trailing record that has no terminating newline so a full parse
        // of the same bytes stays identical, but leave nextOffset at the last LF. Advancing to EOF
        // would desync incremental from a later append that glues bytes onto this record (`A` then
        // `AB\n`). The sqlite cache only stores newline-terminated rows; the pending record is
        // re-parsed on the next refresh.
        if lineStart < data.endIndex, let entry = self.parseLineData(data[lineStart..<data.endIndex]) {
            entries.append(entry)
            completeLineCount += 1
        }
        let consumed = data.distance(from: data.startIndex, to: lastCompleteEnd)
        return JSONLParseResult(
            entries: entries,
            nextOffset: baseOffset + Int64(consumed),
            bytesRead: Int64(data.count),
            completeLineCount: completeLineCount,
            newlineTerminatedEntryCount: newlineTerminatedEntryCount)
    }

    private static func newlineOffsets(in data: Data) -> [Int] {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let scanned: [Int]? = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let count = rawBuffer.count
            var offsets: [Int] = []
            offsets.reserveCapacity(max(1, count / 64))
            var searchStart = 0
            while searchStart < count {
                guard let found = memchr(
                    baseAddress.advanced(by: searchStart),
                    Int32(Self.newline),
                    count - searchStart)
                else {
                    break
                }
                let newlineOffset = baseAddress.distance(to: UnsafeRawPointer(found))
                offsets.append(newlineOffset)
                searchStart = newlineOffset + 1
            }
            return offsets
        }
        if let scanned {
            return scanned
        }
        #endif
        var offsets: [Int] = []
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == Self.newline {
                offsets.append(data.distance(from: data.startIndex, to: index))
            }
            index = data.index(after: index)
        }
        return offsets
    }

    private static func parseLineData(_ line: Data) -> OpenCodexUsageEntry? {
        guard let text = String(data: line, encoding: .utf8) else { return nil }
        return self.parseLine(text)
    }

    private static func parse(_ object: [String: Any]) -> OpenCodexUsageEntry? {
        guard let requestID = self.nonEmptyString(object["requestId"]),
              let timestamp = self.timestamp(object["timestamp"]),
              let provider = self.nonEmptyString(object["provider"]),
              let model = self.nonEmptyString(object["model"])
        else { return nil }
        let status = self.usageStatus(object["usageStatus"])
        let usage = self.usage(object["usage"])
        return OpenCodexUsageEntry(
            requestID: requestID,
            timestamp: timestamp,
            provider: provider,
            model: model,
            usageStatus: status,
            accountLogLabel: self.nonEmptyString(object["accountLogLabel"]),
            surface: self.nonEmptyString(object["surface"]),
            conversationID: self.nonEmptyString(object["conversationId"]),
            usage: usage,
            totalTokens: self.nonnegativeInt(object["totalTokens"]))
    }

    private static func usageStatus(_ value: Any?) -> OpenCodexUsageStatus {
        guard let raw = self.nonEmptyString(value),
              let status = OpenCodexUsageStatus(rawValue: raw)
        else { return .unreported }
        return status
    }

    private static func usage(_ value: Any?) -> OpenCodexTokenUsage? {
        guard let object = value as? [String: Any] else { return nil }
        let parsed = OpenCodexTokenUsage(
            inputTokens: self.nonnegativeInt(object["inputTokens"]),
            outputTokens: self.nonnegativeInt(object["outputTokens"]),
            cachedInputTokens: self.nonnegativeInt(object["cachedInputTokens"]),
            cacheReadInputTokens: self.nonnegativeInt(object["cacheReadInputTokens"]),
            cacheCreationInputTokens: self.nonnegativeInt(object["cacheCreationInputTokens"]),
            reasoningOutputTokens: self.nonnegativeInt(object["reasoningOutputTokens"]),
            totalTokens: self.nonnegativeInt(object["totalTokens"]))
        if parsed.inputTokens == nil,
           parsed.outputTokens == nil,
           parsed.cachedInputTokens == nil,
           parsed.cacheReadInputTokens == nil,
           parsed.cacheCreationInputTokens == nil,
           parsed.reasoningOutputTokens == nil,
           parsed.totalTokens == nil
        {
            return nil
        }
        return parsed
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let number = value as? Double {
            return self.date(fromEpoch: number)
        }
        if let number = value as? Int {
            return self.date(fromEpoch: Double(number))
        }
        if let number = value as? NSNumber {
            return self.date(fromEpoch: number.doubleValue)
        }
        if let raw = value as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(trimmed) {
                return self.date(fromEpoch: number)
            }
            return CostUsageDateParser.parse(trimmed)
        }
        return nil
    }

    private static func date(fromEpoch value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value >= 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? Int {
            return number >= 0 ? number : nil
        }
        if let number = value as? Double, number.isFinite, number >= 0, number <= Double(Int.max) {
            return Int(number)
        }
        if let number = value as? NSNumber {
            let intValue = number.intValue
            return intValue >= 0 ? intValue : nil
        }
        return nil
    }
}
