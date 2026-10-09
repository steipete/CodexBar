import Foundation

/// Reads quota records from a bounded idea.log tail; the IDE can leave its quota XML weeks behind.
enum JetBrainsQuotaLogReader {
    struct Entry: Sendable, Equatable {
        let timestamp: Date
        let quotaInfo: JetBrainsQuotaInfo
        let refillInfo: JetBrainsRefillInfo?
    }

    private static let quotaMarker = "QuotaManager2Impl - New quota state is: "
    private static let refillMarker = "QuotaManager2Impl - New quota refill state is: "
    static let tailByteCount: UInt64 = 4 * 1024 * 1024

    static func logFilePath(
        forIDEBasePath basePath: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String?
    {
        let base = URL(fileURLWithPath: (basePath as NSString).standardizingPath)
        let vendorPath = base.deletingLastPathComponent()
        let vendor = vendorPath.lastPathComponent
        guard ["JetBrains", "Google"].contains(vendor) else { return nil }
        #if os(macOS)
        let configRoots = ["\(homeDirectory)/Library/Application Support/\(vendor)"]
        let logRoot = "\(homeDirectory)/Library/Logs/\(vendor)"
        #else
        let configRoots = ["\(homeDirectory)/.config/\(vendor)", "\(homeDirectory)/.local/share/\(vendor)"]
        let logRoot = "\(homeDirectory)/.cache/\(vendor)"
        #endif
        // A copied or custom config directory does not prove it belongs to this installation's log.
        guard configRoots.contains(vendorPath.path) else { return nil }
        #if os(macOS)
        return "\(logRoot)/\(base.lastPathComponent)/idea.log"
        #else
        return "\(logRoot)/\(base.lastPathComponent)/log/idea.log"
        #endif
    }

    static func latestEntry(atPath path: String) -> Entry? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), let content = self.readTail(from: handle, endOffset: size) else {
            return nil
        }
        return self.latestEntry(inLogContent: content)
    }

    static func latestEntry(inLogContent content: String) -> Entry? {
        var quota: (timestamp: Date, info: JetBrainsQuotaInfo)?
        var refill: JetBrainsRefillInfo?
        var foundRefill = false
        for line in content.split(whereSeparator: \.isNewline).reversed() {
            if line.contains(self.quotaMarker) {
                // Unsupported latest states invalidate the log; never resurrect an older account's quota.
                guard let parsed = self.parseQuotaLine(String(line)) else {
                    if quota == nil { return nil }
                    break
                }
                if quota == nil { quota = parsed }
            } else if !foundRefill, line.contains(self.refillMarker) {
                foundRefill = true
                refill = self.parseRefillLine(String(line))
            }
            if quota != nil, foundRefill { break }
        }
        guard let quota else { return nil }
        return Entry(timestamp: quota.timestamp, quotaInfo: quota.info, refillInfo: refill)
    }

    private static let number = #"([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"#
    private static let details = #"QuotaDetails\(current=\#(number), maximum=\#(number), available=\#(number)\)"#
    private static let quotaRegex = try? NSRegularExpression(pattern:
        #"^Available\(current=\#(number), maximum=\#(number), until=([^,)\s]+), "#
            + #"tariffQuota=\#(details)(?:, topUpQuota=\#(details))?\)$"#)
    private static let refillRegex = try? NSRegularExpression(pattern:
        #"^Known\(next=([^,)\s]+), tariff=QuotaRefillInfoTariff\(amount=\#(number), duration=([^,)\s]+)\)\)$"#)

    static func parseQuotaLine(_ line: String) -> (timestamp: Date, info: JetBrainsQuotaInfo)? {
        guard let record = self.record(in: line, marker: self.quotaMarker),
              let fields = self.captures(self.quotaRegex, in: record.state),
              let until = ISO8601DateParser.parse(fields[2])
        else { return nil }
        let numericFields = fields.enumerated().filter { $0.offset != 2 }.map(\.element)
        let values = numericFields.compactMap(Double.init)
        guard values.count == numericFields.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }), values[3] > 0 else {
            return nil
        }
        // The optional topUpQuota group appends current, maximum, available after the tariff values.
        let topUp = values.count == 8
            ? JetBrainsTopUpQuota(maximum: values[6], available: values[7])
            : nil
        return (record.timestamp, JetBrainsQuotaInfo(
            type: "Available", used: values[2], maximum: values[3], available: values[4], until: until, topUp: topUp))
    }

    static func parseRefillLine(_ line: String) -> JetBrainsRefillInfo? {
        guard let record = self.record(in: line, marker: self.refillMarker),
              let fields = self.captures(self.refillRegex, in: record.state),
              let next = ISO8601DateParser.parse(fields[0]),
              let amount = Double(fields[1]), amount.isFinite, amount >= 0
        else { return nil }
        return JetBrainsRefillInfo(type: "Known", next: next, amount: amount, duration: fields[2])
    }

    private static func record(in line: String, marker: String) -> (timestamp: Date, state: String)? {
        let prefix = String(line.prefix(23))
        guard let range = line.range(of: marker),
              let timestamp = self.timestampFormatter.date(from: prefix),
              self.timestampFormatter.string(from: timestamp) == prefix
        else { return nil }
        return (timestamp, String(line[range.upperBound...]))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return formatter
    }()

    private static func captures(_ regex: NSRegularExpression?, in text: String) -> [String]? {
        guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    static func readTail(from handle: FileHandle, endOffset size: UInt64) -> String? {
        let count = min(size, self.tailByteCount)
        let offset = size - count
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(count)), data.count == count,
              data.last == UInt8(ascii: "\n")
        else { return nil }
        // The window can start in a UTF-8 sequence. An unfinished final line rejects the entire tail.
        let lines = offset > 0
            ? data.firstIndex(of: UInt8(ascii: "\n")).map { data[data.index(after: $0)...] } ?? Data()
            : data[...]
        return String(bytes: lines, encoding: .utf8)
    }
}
