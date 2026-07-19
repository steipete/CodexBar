import Foundation

/// The quota/provider state changes CodexBar can run external commands for.
///
/// Raw values are the stable event names used in config, env vars, and the JSON
/// payload. `cost_threshold_reached` is intentionally not part of v1.
public enum HookEventType: String, Codable, Sendable, CaseIterable {
    case quotaLow = "quota_low"
    case quotaReached = "quota_reached"
    case quotaReset = "quota_reset"
    case providerUnavailable = "provider_unavailable"
    case providerRecovered = "provider_recovered"
    case refreshFailed = "refresh_failed"

    /// Events that can repeat on every refresh while a condition persists, so they
    /// get the rate-limiter backstop. Quota events dedupe upstream and must not be
    /// throttled here, or a lower remaining-quota warning crossing within the
    /// window would be dropped.
    var isRateLimited: Bool {
        switch self {
        case .providerUnavailable, .refreshFailed:
            true
        case .quotaLow, .quotaReached, .quotaReset, .providerRecovered:
            false
        }
    }
}

/// A single quota/provider event, with the metadata handed to an external hook
/// command via environment variables and a JSON stdin payload.
///
/// `usagePercent` is a 0...1 fraction (0.92 == 92% used) to match the spec. It
/// carries only non-secret observability data; `account` is already redacted by
/// the caller when the user hides personal info.
public struct HookEvent: Codable, Sendable, Equatable {
    public let event: HookEventType
    public let provider: String
    public let account: String?
    public let window: String?
    public let usagePercent: Double?
    public let used: Double?
    public let limit: Double?
    public let resetAt: Date?
    public let status: String?
    public let timestamp: Date

    public init(
        event: HookEventType,
        provider: String,
        account: String? = nil,
        window: String? = nil,
        usagePercent: Double? = nil,
        used: Double? = nil,
        limit: Double? = nil,
        resetAt: Date? = nil,
        status: String? = nil,
        timestamp: Date)
    {
        self.event = event
        self.provider = provider
        self.account = account
        self.window = window
        self.usagePercent = usagePercent
        self.used = used
        self.limit = limit
        self.resetAt = resetAt
        self.status = status
        self.timestamp = timestamp
    }

    /// Environment variables passed to the hook command. Nil fields are omitted so
    /// a script can distinguish "absent" from "zero".
    public func environmentVariables() -> [String: String] {
        var env: [String: String] = [
            "CODEXBAR_EVENT": self.event.rawValue,
            "CODEXBAR_PROVIDER": self.provider,
            "CODEXBAR_TIMESTAMP": Self.iso8601String(self.timestamp),
        ]
        if let account { env["CODEXBAR_ACCOUNT"] = account }
        if let window { env["CODEXBAR_WINDOW"] = window }
        if let usagePercent { env["CODEXBAR_USAGE_PERCENT"] = Self.number(usagePercent) }
        if let used { env["CODEXBAR_USED"] = Self.number(used) }
        if let limit { env["CODEXBAR_LIMIT"] = Self.number(limit) }
        if let resetAt { env["CODEXBAR_RESET_AT"] = Self.iso8601String(resetAt) }
        if let status { env["CODEXBAR_STATUS"] = status }
        return env
    }

    /// The JSON written to the hook command's stdin.
    public func jsonPayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func number(_ value: Double) -> String {
        // Trim a trailing ".0" so integers read cleanly, keep fractions intact.
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
