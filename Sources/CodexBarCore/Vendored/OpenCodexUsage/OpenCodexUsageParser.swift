import Foundation

public enum OpenCodexUsageParser {
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
        text.split(whereSeparator: \.isNewline).compactMap { self.parseLine(String($0)) }
    }

    public static func parse(fileURL: URL, fileManager: FileManager = .default) throws -> [OpenCodexUsageEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return self.parseLines(text)
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
