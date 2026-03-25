import Foundation

public struct PerplexityUsageSnapshot: Sendable {
    public let recurringTotal: Double
    public let recurringUsed: Double
    public let promoTotal: Double
    public let promoUsed: Double
    public let purchasedTotal: Double
    public let purchasedUsed: Double
    public let balanceCents: Double
    public let totalUsageCents: Double
    public let renewalDate: Date
    public let promoExpiration: Date?
    public let updatedAt: Date

    public init(response: PerplexityCreditsResponse, now: Date) {
        let recurring = response.creditGrants.filter { $0.type == "recurring" }
        let promotional = response.creditGrants.filter {
            $0.type == "promotional" && ($0.expiresAtTs ?? .infinity) > now.timeIntervalSince1970
        }
        let purchased = response.creditGrants.filter { $0.type == "purchased" }

        // All timestamps from the Perplexity API are Unix seconds (verified Feb 2026).
        let recurringSum = max(0, recurring.reduce(0.0) { $0 + $1.amountCents })
        let promoSum = max(0, promotional.reduce(0.0) { $0 + $1.amountCents })
        // Purchased credits may appear in the top-level field, in the credit_grants
        // array (type == "purchased"), or both. Take whichever is larger to avoid
        // double-counting while still catching either source.
        let purchasedFromGrants = max(0, purchased.reduce(0.0) { $0 + $1.amountCents })
        let purchasedFromField = max(0, response.currentPeriodPurchasedCents)
        let purchasedSum = max(purchasedFromGrants, purchasedFromField)

        // Waterfall attribution: recurring → purchased → promotional
        var remaining = response.totalUsageCents
        let usedFromRecurring = min(remaining, recurringSum); remaining -= usedFromRecurring
        let usedFromPurchased = min(remaining, purchasedSum); remaining -= usedFromPurchased
        let usedFromPromo = min(remaining, promoSum)

        self.recurringTotal = recurringSum
        self.recurringUsed = usedFromRecurring
        self.promoTotal = promoSum
        self.promoUsed = usedFromPromo
        self.purchasedTotal = purchasedSum
        self.purchasedUsed = usedFromPurchased
        self.balanceCents = response.balanceCents
        self.totalUsageCents = response.totalUsageCents
        self.renewalDate = Date(timeIntervalSince1970: response.renewalDateTs)
        self.promoExpiration = promotional
            .compactMap { $0.expiresAtTs.map { Date(timeIntervalSince1970: $0) } }
            .min()
        self.updatedAt = now
    }

    /// Infer plan name from recurring credit allotment.
    /// Free = 0, Pro = small pool (~500–1000), Max = 10,000+.
    public var planName: String? {
        if self.recurringTotal <= 0 { return nil }
        if self.recurringTotal < 5000 { return "Pro" }
        return "Max"
    }

    private static let promoExpiryFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt
    }()
}

extension PerplexityUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary: recurring (monthly) credits
        let hasFallbackCredits = self.promoTotal > 0 || self.purchasedTotal > 0
        let primaryWindow: RateWindow? = {
            if self.recurringTotal > 0 {
                let primaryPercent = min(100, max(0, self.recurringUsed / self.recurringTotal * 100))
                return RateWindow(
                    usedPercent: primaryPercent,
                    windowMinutes: nil,
                    resetsAt: self.renewalDate,
                    resetDescription: "\(Int(self.recurringUsed.rounded()))/\(Int(self.recurringTotal)) credits")
            }
            if hasFallbackCredits {
                // When recurring is absent but bonus/purchased credits remain, omit the fake 0/0 primary lane
                // so automatic menu-bar rendering can fall through to the usable pool.
                return nil
            }
            return RateWindow(
                usedPercent: 100,
                windowMinutes: nil,
                resetsAt: self.renewalDate,
                resetDescription: "0/0 credits")
        }()

        // Secondary: promotional bonus credits — always shown.
        // usedPercent=100 when promoTotal==0 so the bar renders empty rather than full.
        let promoPercent = self.promoTotal > 0
            ? min(100, max(0, self.promoUsed / self.promoTotal * 100))
            : 100.0
        var promoDesc = "\(Int(promoUsed.rounded()))/\(Int(self.promoTotal)) bonus"
        if let expiry = promoExpiration {
            promoDesc += " \u{00b7} exp. \(Self.promoExpiryFormatter.string(from: expiry))"
        }
        let secondary = RateWindow(
            usedPercent: promoPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: promoDesc)

        // Tertiary: on-demand purchased credits — always shown.
        // usedPercent=100 when purchasedTotal==0 so the bar renders empty rather than full.
        let purchasedPercent = self.purchasedTotal > 0
            ? min(100, max(0, self.purchasedUsed / self.purchasedTotal * 100))
            : 100.0
        let tertiary = RateWindow(
            usedPercent: purchasedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "\(Int(purchasedUsed.rounded()))/\(Int(self.purchasedTotal)) credits")

        let identity = ProviderIdentitySnapshot(
            providerID: .perplexity,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: planName)

        return UsageSnapshot(
            primary: primaryWindow,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
