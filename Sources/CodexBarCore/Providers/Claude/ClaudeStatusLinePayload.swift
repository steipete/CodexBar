import Foundation

/// One rate-limit window as published by Claude Code to its configured statusLine command.
public struct ClaudeStatusLineWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// A single statusLine observation, attributed to the Claude profile that produced it.
public struct ClaudeStatusLineRateLimits: Equatable, Sendable {
    /// `CLAUDE_CONFIG_DIR` of the reporting session; nil for the ambient default profile.
    public let configDir: String?
    public let capturedAt: Date
    public let fiveHour: ClaudeStatusLineWindow?
    public let sevenDay: ClaudeStatusLineWindow?

    public init(
        configDir: String?,
        capturedAt: Date,
        fiveHour: ClaudeStatusLineWindow?,
        sevenDay: ClaudeStatusLineWindow?)
    {
        self.configDir = configDir
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// Parses the payload a user-configured Claude statusLine command forwards to CodexBar.
///
/// Every failure returns nil. The status line is the user's own configuration and Claude Code may change the
/// schema at any time, so a drifted payload has to read as "no live data" and leave the polled sources
/// untouched — never as an error on the card (AGENTS.md, owner ruling on #2733).
public enum ClaudeStatusLinePayloadParser {
    /// Envelope version this build understands. An unknown version is absence, not an error.
    public static let currentSchemaVersion = 1

    public static func parse(_ data: Data, now: Date = Date()) -> ClaudeStatusLineRateLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let schema = self.finiteNumber(root["schema"]), Int(schema) == self.currentSchemaVersion else {
            return nil
        }
        guard let payload = self.object(root["payload"]),
              let rateLimits = self.object(payload["rate_limits"])
        else { return nil }

        let fiveHour = self.window(rateLimits["five_hour"])
        let sevenDay = self.window(rateLimits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return ClaudeStatusLineRateLimits(
            configDir: self.nonemptyString(root["configDir"]),
            capturedAt: self.date(root["capturedAt"]) ?? now,
            fiveHour: fiveHour,
            sevenDay: sevenDay)
    }

    // MARK: - Field decoding

    /// The shim buffers Claude's stdin verbatim, so the payload may arrive as an object or as an embedded string.
    private static func object(_ raw: Any?) -> [String: Any]? {
        if let object = raw as? [String: Any] { return object }
        guard let text = self.nonemptyString(raw), let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func window(_ raw: Any?) -> ClaudeStatusLineWindow? {
        guard let object = self.object(raw) else { return nil }
        // `utilization` is the OAuth-shaped sibling of `used_percentage`; accepting both means a rename
        // upstream degrades to one missing window rather than a silent dark feed.
        guard let used = self.finiteNumber(object["used_percentage"]) ?? self.finiteNumber(object["utilization"])
        else { return nil }
        // A percentage outside 0...100 means the schema no longer says what we think it says.
        guard (0...100).contains(used) else { return nil }
        return ClaudeStatusLineWindow(usedPercent: used, resetsAt: self.date(object["resets_at"]))
    }

    private static func date(_ raw: Any?) -> Date? {
        if let seconds = self.finiteNumber(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = self.nonemptyString(raw) else { return nil }
        if let seconds = Double(text), seconds.isFinite {
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        // Foundation bridges JSON booleans to NSNumber, so `as? Double` would accept `true`. `is Bool` cannot
        // separate them either — it answers true for the numbers 0 and 1 — so compare the CoreFoundation type.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func nonemptyString(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
