import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

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
        self.availableInventory(at: self.updatedAt).nextExpiringCredit
    }

    public func availableInventory(at date: Date) -> CodexRateLimitResetCreditInventory {
        CodexRateLimitResetCreditInventory(credits: self.credits, at: date)
    }

    public func availableCredits(at date: Date) -> [CodexRateLimitResetCredit] {
        self.availableInventory(at: date).credits
    }
}

public struct CodexRateLimitResetCreditInventory: Equatable, Sendable {
    public let credits: [CodexRateLimitResetCredit]

    public var count: Int {
        self.credits.count
    }

    public var nextExpiringCredit: CodexRateLimitResetCredit? {
        self.credits.first { $0.expiresAt != nil }
    }

    public init(credits: [CodexRateLimitResetCredit], at date: Date) {
        self.credits = credits
            .filter { credit in
                credit.status == .available && (credit.expiresAt.map { $0 > date } ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.id < rhs.id
            }
    }
}

public struct CodexRateLimitResetCredit: Equatable, Codable, Sendable, Identifiable {
    private static let stableIDPrefix = "codex-reset-credit-v1-"

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
        self.id = Self.stableID(forProviderID: id)
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.redeemStartedAt = redeemStartedAt
        self.redeemedAt = redeemedAt
        self.title = title
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
        let resetType = try container.decode(String.self, forKey: .resetType)
        let status = try container.decode(CodexRateLimitResetCreditStatus.self, forKey: .status)
        let grantedAt = try container.decode(Date.self, forKey: .grantedAt)
        let expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        let redeemStartedAt = try container.decodeIfPresent(Date.self, forKey: .redeemStartedAt)
        let redeemedAt = try container.decodeIfPresent(Date.self, forKey: .redeemedAt)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let description = try container.decodeIfPresent(String.self, forKey: .description)

        if Self.isCanonicalStableID(decodedID) {
            self.init(
                persistedStableID: decodedID,
                resetType: resetType,
                status: status,
                grantedAt: grantedAt,
                expiresAt: expiresAt,
                redeemStartedAt: redeemStartedAt,
                redeemedAt: redeemedAt,
                title: title,
                description: description)
        } else {
            self.init(
                id: decodedID,
                resetType: resetType,
                status: status,
                grantedAt: grantedAt,
                expiresAt: expiresAt,
                redeemStartedAt: redeemStartedAt,
                redeemedAt: redeemedAt,
                title: title,
                description: description)
        }
    }

    static func stableID(forProviderID providerID: String) -> String {
        let domainSeparatedValue = "com.steipete.CodexBar.reset-credit-id.v1\0\(providerID)"
        let digest = SHA256.hash(data: Data(domainSeparatedValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return Self.stableIDPrefix + digest
    }

    private init(
        persistedStableID: String,
        resetType: String,
        status: CodexRateLimitResetCreditStatus,
        grantedAt: Date,
        expiresAt: Date?,
        redeemStartedAt: Date?,
        redeemedAt: Date?,
        title: String?,
        description: String?)
    {
        precondition(Self.isCanonicalStableID(persistedStableID))
        self.id = persistedStableID
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.redeemStartedAt = redeemStartedAt
        self.redeemedAt = redeemedAt
        self.title = title
        self.description = description
    }

    private static func isCanonicalStableID(_ id: String) -> Bool {
        guard id.hasPrefix(self.stableIDPrefix) else { return false }
        let digest = id.dropFirst(Self.stableIDPrefix.count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
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
