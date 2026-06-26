import Foundation

struct KimiUsageResponse: Codable {
    let usages: [KimiUsage]
    let user: KimiUser?
}

struct KimiCodeAPIUsageResponse: Codable {
    let usage: KimiUsageDetail
    let limits: [KimiRateLimit]?
    let user: KimiUser?
}

struct KimiUser: Codable, Sendable {
    let membership: KimiMembership?
}

struct KimiMembership: Codable, Sendable {
    let level: String?
}

enum KimiMembershipLevel {
    private static let names: [String: String] = [
        "LEVEL_FREE": "Free",
        "LEVEL_BASIC": "Andante",
        "LEVEL_STANDARD": "Moderato",
        "LEVEL_INTERMEDIATE": "Allegretto",
        "LEVEL_ADVANCED": "Allegro",
        "LEVEL_PREMIUM": "Vivace",
    ]

    static func displayName(_ rawLevel: String?) -> String? {
        guard let rawLevel = rawLevel?.trimmingCharacters(in: .whitespacesAndNewlines), !rawLevel.isEmpty else {
            return nil
        }
        return self.names[rawLevel] ?? rawLevel
    }
}

struct KimiCodeAPIModelsResponse: Codable {
    let data: [KimiCodeAPIModel]
}

struct KimiCodeAPIModel: Codable, Sendable {
    let id: String
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

enum KimiCodePricing {
    // Pricing per million tokens in USD, matching pi-provider-kimi-code.
    // Source: https://platform.kimi.com/docs/pricing/chat-k27-code
    private static let standard = Rates(input: 0.897, output: 3.724, cacheRead: 0.179, cacheWrite: 0.897)
    private static let highSpeed = Rates(input: 1.793, output: 7.448, cacheRead: 0.359, cacheWrite: 1.793)

    private struct Rates {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    static func isHighSpeed(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.range(of: #"high\s*[- ]?\s*speed|fast"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func modeLabel(displayName: String?) -> String? {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty
        else {
            return nil
        }
        return self.isHighSpeed(displayName) ? "High Speed" : "Standard"
    }

    static func costUSD(
        modelName: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int) -> Double
    {
        let rates = self.isHighSpeed(modelName) ? self.highSpeed : self.standard
        return (Double(inputTokens) * rates.input
            + Double(cacheReadTokens) * rates.cacheRead
            + Double(cacheWriteTokens) * rates.cacheWrite
            + Double(outputTokens) * rates.output) / 1_000_000
    }
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

struct KimiRateLimit: Codable, Sendable {
    let window: KimiWindow
    let detail: KimiUsageDetail
}

struct KimiWindow: Codable, Sendable {
    let duration: Int
    let timeUnit: String
}
