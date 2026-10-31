import Foundation
@testable import CodexBarCore

public struct PerplexityCreditsResponse: Codable {
    public let balanceCents: Double
    public let renewalDateTs: TimeInterval
    public let currentPeriodPurchasedCents: Double
    public let creditGrants: [PerplexityCreditGrant]
    public let totalUsageCents: Double
    public let orgPoolDrawsCents: Double?
    public let orgUserCapCents: Double?
    public let isOrgPoolDepleted: Bool?

    enum CodingKeys: String, CodingKey {
        case balanceCents = "balance_cents"
        case renewalDateTs = "renewal_date_ts"
        case currentPeriodPurchasedCents = "current_period_purchased_cents"
        case creditGrants = "credit_grants"
        case totalUsageCents = "total_usage_cents"
        case orgPoolDrawsCents = "org_pool_draws_cents"
        case orgUserCapCents = "org_user_cap_cents"
        case isOrgPoolDepleted = "is_org_pool_depleted"
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
