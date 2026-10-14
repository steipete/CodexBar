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
    /// After the AI Assistant → Air migration the IDE stops logging quota state; Junie relays it as JSON instead.
    private static let junieQuotaMarker = "AiaActivationTransmitter - Received message from junie: quota_update:"
    /// Once Air disables AI Assistant, its quota manager keeps logging this error between Junie's updates.
    private static let disabledAssistantState = "Error(exception=com.intellij.ml.llm.core.AIAssistantForbiddenException"
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
            // A disabled assistant says nothing about the account; other errors still invalidate the log below.
            if line.contains(self.quotaMarker + self.disabledAssistantState) { continue }
            let isLegacyQuota = line.contains(self.quotaMarker)
            if isLegacyQuota || line.contains(self.junieQuotaMarker) {
                // Unsupported latest states invalidate the log; never resurrect an older account's quota.
                let parsed = isLegacyQuota ? self.parseQuotaLine(String(line)) : self.parseJunieQuotaLine(String(line))
                guard let parsed else {
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
    // AI Assistant 262.x wraps the same fields in `JbaiQuota(...)`; identifiers are matched but never captured.
    private static let jbaiDetails = #"Details\(current=\#(number), maximum=\#(number), available=\#(number)\)"#
    private static let jbaiQuotaRegex = try? NSRegularExpression(pattern:
        #"^Available\(quota=JbaiQuota\(license=[^,()]*, current=\#(number), maximum=\#(number), "#
            + #"quotaID=JbaiQuotaId\([^()]*\), until=([^,)\s]+), "#
            + #"tariffQuota=\#(jbaiDetails)(?:, topUpQuota=\#(jbaiDetails))?\)\)$"#)
    private static let jbaiRefillRegex = try? NSRegularExpression(pattern:
        #"^Known\(refill=JbaiQuotaRefill\(tariff=JbaiQuotaTariff\(amount=\#(number), period=([^,)\s]+)\), "#
            + #"next=([^,)\s]+), last=[^,)\s]+\)\)$"#)

    static func parseQuotaLine(_ line: String) -> (timestamp: Date, info: JetBrainsQuotaInfo)? {
        guard let record = self.record(in: line, marker: self.quotaMarker),
              let fields = self.captures(self.quotaRegex, in: record.state)
              ?? self.captures(self.jbaiQuotaRegex, in: record.state),
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

    private struct JunieQuotaUpdate: Decodable {
        struct Amount: Decodable {
            let value: Double

            enum CodingKeys: String, CodingKey { case amount }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try? container.decode(String.self, forKey: .amount), let value = Double(text) {
                    self.value = value
                } else {
                    self.value = try container.decode(Double.self, forKey: .amount)
                }
            }
        }

        struct Details: Decodable {
            let current: Amount
            let maximum: Amount
            let available: Amount
        }

        let until: Double
        let tariffQuota: Details
        let topUpQuota: Details?
    }

    static func parseJunieQuotaLine(_ line: String) -> (timestamp: Date, info: JetBrainsQuotaInfo)? {
        // Only the quota amounts are decoded; the license and other payload fields are never retained.
        guard let record = self.record(in: line, marker: self.junieQuotaMarker),
              let update = try? JSONDecoder().decode(JunieQuotaUpdate.self, from: Data(record.state.utf8))
        else { return nil }
        let tariff = update.tariffQuota
        let values = [tariff.current.value, tariff.maximum.value, tariff.available.value, update.until]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), tariff.maximum.value > 0 else { return nil }
        return (record.timestamp, JetBrainsQuotaInfo(
            type: "Available",
            used: tariff.current.value,
            maximum: tariff.maximum.value,
            available: tariff.available.value,
            until: Date(timeIntervalSince1970: update.until / 1000),
            topUp: update.topUpQuota.flatMap {
                JetBrainsTopUpQuota(maximum: $0.maximum.value, available: $0.available.value)
            }))
    }

    static func parseRefillLine(_ line: String) -> JetBrainsRefillInfo? {
        guard let record = self.record(in: line, marker: self.refillMarker) else { return nil }
        // Normalize both layouts to (next, amount, duration).
        let fields: [String]? = if let legacy = self.captures(self.refillRegex, in: record.state) {
            legacy
        } else if let jbai = self.captures(self.jbaiRefillRegex, in: record.state), jbai.count == 3 {
            [jbai[2], jbai[0], jbai[1]]
        } else {
            nil
        }
        guard let fields,
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
