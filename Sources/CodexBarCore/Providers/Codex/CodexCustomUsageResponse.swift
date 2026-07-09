import Foundation

/// Decodable shape of a custom-provider-style `GET /v1/usage` response.
///
/// `daily_usage` and `model_stats` are decoded for forward compatibility but
/// are not rendered in this iteration.
struct CodexCustomUsageResponse: Decodable, Sendable {
    let remaining: Double?
    let unit: String?
    let isValid: Bool?
    let planName: String?
    let subscription: Subscription?
    let dailyUsage: [DailyUsage]?
    let modelStats: [ModelStats]?

    init(from decoder: Decoder) throws {
        // The PRD records the top-level keys as camelCase (`isValid`, `planName`);
        // tolerate the snake_case spellings too so the mapper is robust to either
        // convention the provider settles on.
        let container = try decoder.container(keyedBy: TopLevelCodingKeys.self)
        self.remaining = try container.decodeIfPresent(Double.self, forKey: .remaining)
        self.unit = try container.decodeIfPresent(String.self, forKey: .unit)
        self.isValid = try container.decodeIfPresent(Bool.self, forKey: .isValid)
            ?? container.decodeIfPresent(Bool.self, forKey: .isValidSnake)
        self.planName = try container.decodeIfPresent(String.self, forKey: .planName)
            ?? container.decodeIfPresent(String.self, forKey: .planNameSnake)
        self.subscription = try container.decodeIfPresent(Subscription.self, forKey: .subscription)
        self.dailyUsage = try container.decodeIfPresent([DailyUsage].self, forKey: .dailyUsage)
        self.modelStats = try container.decodeIfPresent([ModelStats].self, forKey: .modelStats)
    }

    private enum TopLevelCodingKeys: String, CodingKey {
        case remaining
        case unit
        case isValid
        case isValidSnake = "is_valid"
        case planName
        case planNameSnake = "plan_name"
        case subscription
        case dailyUsage = "daily_usage"
        case modelStats = "model_stats"
    }

    struct Subscription: Decodable, Sendable {
        let dailyLimitUSD: Double?
        let dailyUsageUSD: Double?
        let weeklyLimitUSD: Double?
        let weeklyUsageUSD: Double?
        let monthlyLimitUSD: Double?
        let monthlyUsageUSD: Double?
        let expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case dailyLimitUSD = "daily_limit_usd"
            case dailyUsageUSD = "daily_usage_usd"
            case weeklyLimitUSD = "weekly_limit_usd"
            case weeklyUsageUSD = "weekly_usage_usd"
            case monthlyLimitUSD = "monthly_limit_usd"
            case monthlyUsageUSD = "monthly_usage_usd"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.dailyLimitUSD = try container.decodeIfPresent(Double.self, forKey: .dailyLimitUSD)
            self.dailyUsageUSD = try container.decodeIfPresent(Double.self, forKey: .dailyUsageUSD)
            self.weeklyLimitUSD = try container.decodeIfPresent(Double.self, forKey: .weeklyLimitUSD)
            self.weeklyUsageUSD = try container.decodeIfPresent(Double.self, forKey: .weeklyUsageUSD)
            self.monthlyLimitUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyLimitUSD)
            self.monthlyUsageUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyUsageUSD)
            self.expiresAt = try Self.decodeDate(from: container, forKey: .expiresAt)
        }

        private static func decodeDate(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys) throws -> Date?
        {
            guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
            if let date = Self.iso8601(fractionalSeconds: true).date(from: raw) {
                return date
            }
            return Self.iso8601(fractionalSeconds: false).date(from: raw)
        }

        private static func iso8601(fractionalSeconds: Bool) -> ISO8601DateFormatter {
            let formatter = ISO8601DateFormatter()
            if fractionalSeconds {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            }
            return formatter
        }
    }

    struct DailyUsage: Decodable, Sendable {
        let date: String?
        let usageUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case date
            case usageUSD = "usage_usd"
        }
    }

    struct ModelStats: Decodable, Sendable {
        let model: String?
        let usageUSD: Double?
        let requests: Int?

        private enum CodingKeys: String, CodingKey {
            case model
            case usageUSD = "usage_usd"
            case requests
        }
    }

    private enum CodingKeys: String, CodingKey {
        case remaining
        case unit
        case isValid = "is_valid"
        case planName = "plan_name"
        case subscription
        case dailyUsage = "daily_usage"
        case modelStats = "model_stats"
    }
}
