import Foundation

public struct CreditEvent: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public let date: Date
    public let service: String
    public let creditsUsed: Double

    public init(id: UUID = UUID(), date: Date, service: String, creditsUsed: Double) {
        self.id = id
        self.date = date
        self.service = service
        self.creditsUsed = creditsUsed
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case service
        case creditsUsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.date = try container.decode(Date.self, forKey: .date)
        self.service = try container.decode(String.self, forKey: .service)
        self.creditsUsed = try container.decode(Double.self, forKey: .creditsUsed)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.date, forKey: .date)
        try container.encode(self.service, forKey: .service)
        try container.encode(self.creditsUsed, forKey: .creditsUsed)
    }
}

public struct CreditsSnapshot: Equatable, Codable, Sendable {
    public let remaining: Double
    public let events: [CreditEvent]
    public let updatedAt: Date
    public let codexCreditLimit: CodexCreditLimitSnapshot?

    public init(
        remaining: Double,
        events: [CreditEvent],
        updatedAt: Date,
        codexCreditLimit: CodexCreditLimitSnapshot? = nil)
    {
        self.remaining = remaining
        self.events = events
        self.updatedAt = updatedAt
        self.codexCreditLimit = codexCreditLimit
    }
}

public struct CodexCreditLimitSnapshot: Equatable, Codable, Sendable {
    public let title: String
    public let used: Double
    public let limit: Double
    public let remaining: Double
    public let remainingPercent: Double
    public let resetsAt: Date?
    public let updatedAt: Date

    public init(
        title: String = "Monthly credit limit",
        used: Double,
        limit: Double,
        remainingPercent: Double,
        resetsAt: Date?,
        updatedAt: Date)
    {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Monthly credit limit"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.used = max(0, used)
        self.limit = max(0, limit)
        self.remaining = max(0, self.limit - self.used)
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
    }

    public var usedPercent: Double {
        min(100, max(0, 100 - self.remainingPercent))
    }
}

public struct CodexRateLimitResetCreditsSnapshot: Equatable, Codable, Sendable {
    public let credits: [CodexRateLimitResetCredit]
    public let availableCount: Int
    public let updatedAt: Date

    public init(credits: [CodexRateLimitResetCredit], availableCount: Int, updatedAt: Date) {
        self.credits = credits
        self.availableCount = availableCount
        self.updatedAt = updatedAt
    }

    public var nextExpiringAvailableCredit: CodexRateLimitResetCredit? {
        self.credits
            .filter { credit in
                credit.status == .available && (credit.expiresAt ?? .distantPast) > self.updatedAt
            }
            .min { lhs, rhs in
                guard let lhsExpiresAt = lhs.expiresAt else { return false }
                guard let rhsExpiresAt = rhs.expiresAt else { return true }
                return lhsExpiresAt < rhsExpiresAt
            }
    }
}

public struct CodexRateLimitResetCredit: Equatable, Codable, Sendable, Identifiable {
    public let id: String
    public let resetType: String
    public let status: CodexRateLimitResetCreditStatus
    public let grantedAt: Date
    public let expiresAt: Date?
    public let redeemStartedAt: Date?
    public let redeemedAt: Date?
    public let title: String?
    public let description: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case redeemStartedAt = "redeem_started_at"
        case redeemedAt = "redeemed_at"
        case title
        case description
    }

    public init(
        id: String,
        resetType: String,
        status: CodexRateLimitResetCreditStatus,
        grantedAt: Date,
        expiresAt: Date?,
        redeemStartedAt: Date?,
        redeemedAt: Date?,
        title: String?,
        description: String?)
    {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.redeemStartedAt = redeemStartedAt
        self.redeemedAt = redeemedAt
        self.title = title
        self.description = description
    }
}

public enum CodexRateLimitResetCreditStatus: Equatable, Codable, Sendable {
    case available
    case redeeming
    case redeemed
    case expired
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "available":
            self = .available
        case "redeeming":
            self = .redeeming
        case "redeemed":
            self = .redeemed
        case "expired":
            self = .expired
        default:
            self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public var rawValue: String {
        switch self {
        case .available:
            "available"
        case .redeeming:
            "redeeming"
        case .redeemed:
            "redeemed"
        case .expired:
            "expired"
        case let .unknown(value):
            value
        }
    }
}
