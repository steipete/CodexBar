import Foundation

struct KimiUsageResponse: Codable {
    let usages: [KimiUsage]
}

struct KimiCodeAPIUsageResponse: Codable {
    let usage: KimiUsageDetail
    let limits: [KimiRateLimit]?
}

struct KimiSubscriptionStatsResponse: Codable {
    let subscriptionBalance: KimiSubscriptionBalance?
    let ratelimitCode7d: KimiSubscriptionRateLimit?
}

struct KimiSubscriptionBalance: Codable, Sendable {
    let feature: String?
    let type: String?
    let amountUsedRatio: Double?
    let expireTime: String?
}

struct KimiSubscriptionRateLimit: Codable, Sendable {
    let ratio: Double?
    let enabled: Bool?
    let resetTime: String?
}

struct KimiUsage: Codable {
    let scope: String
    let detail: KimiUsageDetail
    let limits: [KimiRateLimit]?
}

public struct KimiUsageDetail: Codable, Sendable {
    public let limit: String
    public let used: String?
    public let remaining: String?
    public let resetTime: String?

    private enum CodingKeys: String, CodingKey {
        case limit
        case used
        case remaining
        case resetTime
        case resetAt
        case resetTimeSnake = "reset_time"
        case resetAtSnake = "reset_at"
    }

    public init(limit: String, used: String?, remaining: String?, resetTime: String?) {
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.resetTime = resetTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let limit = Self.stringValue(in: container, forKey: .limit) else {
            throw DecodingError.keyNotFound(
                CodingKeys.limit,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Kimi usage limit is missing"))
        }

        self.limit = limit
        self.used = Self.stringValue(in: container, forKey: .used)
        self.remaining = Self.stringValue(in: container, forKey: .remaining)
        self.resetTime =
            Self.stringValue(in: container, forKey: .resetTime) ??
            Self.stringValue(in: container, forKey: .resetAt) ??
            Self.stringValue(in: container, forKey: .resetTimeSnake) ??
            Self.stringValue(in: container, forKey: .resetAtSnake)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.limit, forKey: .limit)
        try container.encodeIfPresent(self.used, forKey: .used)
        try container.encodeIfPresent(self.remaining, forKey: .remaining)
        try container.encodeIfPresent(self.resetTime, forKey: .resetTime)
    }

    private static func stringValue(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> String?
    {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            if value.rounded(.towardZero) == value,
               value >= Double(Int64.min),
               value <= Double(Int64.max)
            {
                return String(Int64(value))
            }
            return String(value)
        }
        return nil
    }
}

struct KimiRateLimit: Codable {
    let window: KimiWindow
    let detail: KimiUsageDetail
}

struct KimiWindow: Codable {
    let duration: Int
    let timeUnit: String
}
