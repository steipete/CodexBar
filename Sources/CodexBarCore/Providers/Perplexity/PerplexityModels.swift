import Foundation

public struct PerplexityCreditsResponse: Codable {
    public let balanceCents: Double
    public let renewalDateTs: TimeInterval
    public let currentPeriodPurchasedCents: Double
    public let creditGrants: [PerplexityCreditGrant]
    public let totalUsageCents: Double

    enum CodingKeys: String, CodingKey {
        case balanceCents = "balance_cents"
        case renewalDateTs = "renewal_date_ts"
        case currentPeriodPurchasedCents = "current_period_purchased_cents"
        case creditGrants = "credit_grants"
        case totalUsageCents = "total_usage_cents"
    }
}

public struct PerplexityCreditGrant: Codable {
    public let type: String
    public let amountCents: Double
    public let expiresAtTs: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case type
        case amountCents = "amount_cents"
        case expiresAtTs = "expires_at_ts"
    }
}
