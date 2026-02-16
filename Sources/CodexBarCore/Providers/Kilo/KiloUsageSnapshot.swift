import Foundation

public struct KiloAutoTopUp: Sendable {
    public let enabled: Bool
    public let amountDollars: Double

    public init(enabled: Bool, amountDollars: Double) {
        self.enabled = enabled
        self.amountDollars = amountDollars
    }
}

public struct KiloUsageSnapshot: Sendable {
    public let balanceDollars: Double          // Current credit balance from API
    public let periodBaseCredits: Double        // Base credits in plan ($19)
    public let periodBonusCredits: Double       // Bonus credits ($9.50)
    public let periodUsageDollars: Double       // Usage this period
    public let periodResetsAt: Date?            // Next billing date
    public let hasSubscription: Bool            // Whether user has active Kilo Pass
    public let planName: String?                // Subscription plan name (e.g. "Starter")
    public let creditBlocks: [KiloCreditBlock]  // Individual credit blocks from API
    public let autoTopUp: KiloAutoTopUp?        // Auto top-up settings
    public let cliCostDollars: Double           // CLI total cost
    public let cliSessions: Int                 // CLI sessions
    public let cliMessages: Int                 // CLI messages
    public let cliInputTokens: Int              // CLI input tokens
    public let cliOutputTokens: Int             // CLI output tokens
    public let cliCacheReadTokens: Int          // CLI cache read tokens
    public let updatedAt: Date

    public init(
        balanceDollars: Double = 0,
        periodBaseCredits: Double = 0,
        periodBonusCredits: Double = 0,
        periodUsageDollars: Double = 0,
        periodResetsAt: Date? = nil,
        hasSubscription: Bool = false,
        planName: String? = nil,
        creditBlocks: [KiloCreditBlock] = [],
        autoTopUp: KiloAutoTopUp? = nil,
        cliCostDollars: Double = 0,
        cliSessions: Int = 0,
        cliMessages: Int = 0,
        cliInputTokens: Int = 0,
        cliOutputTokens: Int = 0,
        cliCacheReadTokens: Int = 0,
        updatedAt: Date)
    {
        self.balanceDollars = balanceDollars
        self.periodBaseCredits = periodBaseCredits
        self.periodBonusCredits = periodBonusCredits
        self.periodUsageDollars = periodUsageDollars
        self.periodResetsAt = periodResetsAt
        self.hasSubscription = hasSubscription
        self.planName = planName
        self.creditBlocks = creditBlocks
        self.autoTopUp = autoTopUp
        self.cliCostDollars = cliCostDollars
        self.cliSessions = cliSessions
        self.cliMessages = cliMessages
        self.cliInputTokens = cliInputTokens
        self.cliOutputTokens = cliOutputTokens
        self.cliCacheReadTokens = cliCacheReadTokens
        self.updatedAt = updatedAt
    }
}

extension KiloUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .kilo,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: planName)

        // Only show Kilo Pass usage bar if user has an active subscription
        var primary: RateWindow? = nil
        if hasSubscription {
            let totalCredits = periodBaseCredits + periodBonusCredits
            var usedPercent: Double = 0
            var resetDesc: String
            var bonusMarkerPercent: Double? = nil

            if totalCredits > 0 {
                usedPercent = min(100, (periodUsageDollars / totalCredits) * 100)
                if periodBonusCredits > 0 {
                    resetDesc = String(format: "$%.2f / $%.2f (+ $%.2f bonus)", periodUsageDollars, periodBaseCredits, periodBonusCredits)
                    // Marker at the boundary between bonus (consumed first) and base credits
                    bonusMarkerPercent = (periodBonusCredits / totalCredits) * 100
                } else {
                    resetDesc = String(format: "$%.2f / $%.2f", periodUsageDollars, periodBaseCredits)
                }
            } else {
                resetDesc = String(format: "$%.2f / $%.2f", periodUsageDollars, periodBaseCredits)
            }

            primary = RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: periodResetsAt,
                resetDescription: resetDesc,
                markerPercent: bonusMarkerPercent)
        }

        // Provider cost carries CLI stats for display in the "Cost" section
        var providerCost: ProviderCostSnapshot? = nil
        if cliCostDollars > 0 || cliSessions > 0 {
            var detailParts: [String] = []
            if cliSessions > 0 { detailParts.append("\(cliSessions) sessions") }
            if cliMessages > 0 { detailParts.append("\(cliMessages) messages") }
            let totalTokens = cliInputTokens + cliOutputTokens + cliCacheReadTokens
            if totalTokens > 0 { detailParts.append("\(UsageFormatter.tokenCountString(totalTokens)) tokens") }
            let detailLine = detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")

            // limit: 0 ensures providerCostSection() skips the "Extra usage" progress bar.
            // The cost data is instead read by tokenUsageSection() for a text-only "Cost" display.
            providerCost = ProviderCostSnapshot(
                used: cliCostDollars,
                limit: 0,
                currencyCode: "USD",
                period: detailLine,
                resetsAt: nil,
                updatedAt: updatedAt)
        }

        // Consolidate credit blocks: merge non-expiring into one, keep expiring separate
        let consolidatedBlocks = Self.consolidateCreditBlocks(creditBlocks)

        // Auto top-up text
        var autoTopUpText: String? = nil
        if let topUp = autoTopUp, topUp.enabled {
            if topUp.amountDollars > 0 {
                autoTopUpText = String(format: "Auto top-up: $%.0f", topUp.amountDollars)
            } else {
                autoTopUpText = "Auto top-up: On"
            }
        }

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: providerCost,
            kiloCreditBlocks: consolidatedBlocks.isEmpty ? nil : consolidatedBlocks,
            kiloAutoTopUpText: autoTopUpText,
            updatedAt: updatedAt,
            identity: identity)
    }

    /// Merge all non-expiring credit blocks into a single entry; keep expiring ones individual.
    private static func consolidateCreditBlocks(_ blocks: [KiloCreditBlock]) -> [KiloCreditBlock] {
        var expiring: [KiloCreditBlock] = []
        var permanentBalance: Int = 0
        var permanentAmount: Int = 0
        var permanentDate: String = ""
        var permanentCount: Int = 0
        var permanentFreeCount: Int = 0

        for block in blocks {
            if block.expiryDateString != nil {
                expiring.append(block)
            } else {
                permanentBalance += block.balanceMUsd
                permanentAmount += block.amountMUsd
                permanentCount += 1
                if block.isFree { permanentFreeCount += 1 }
                // Use the earliest effective date for the consolidated entry
                if permanentDate.isEmpty || block.effectiveDateString < permanentDate {
                    permanentDate = block.effectiveDateString
                }
            }
        }

        var result: [KiloCreditBlock] = []
        if permanentAmount > 0 {
            let allFree = permanentCount > 0 && permanentFreeCount == permanentCount
            result.append(KiloCreditBlock(
                id: "consolidated-permanent",
                effectiveDateString: permanentDate,
                expiryDateString: nil,
                balanceMUsd: permanentBalance,
                amountMUsd: permanentAmount,
                isFree: allFree))
        }
        result.append(contentsOf: expiring)
        return result
    }
}
