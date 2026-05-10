import Foundation

/// Static catalog of CommandCode subscription plans → monthly credit allowance (in USD).
///
/// The `/internal/billing/credits` endpoint exposes the *remaining* `monthlyCredits`,
/// not the plan total. The plan total is published on the public pricing page
/// (https://commandcode.ai/pricing) and is keyed by `planId` returned from
/// `/internal/billing/subscriptions`.
public enum CommandCodePlanCatalog {
    public struct Plan: Sendable, Equatable {
        public let id: String
        public let displayName: String
        /// Monthly credit allowance in USD.
        public let monthlyCreditsUSD: Double

        public init(id: String, displayName: String, monthlyCreditsUSD: Double) {
            self.id = id
            self.displayName = displayName
            self.monthlyCreditsUSD = monthlyCreditsUSD
        }
    }

    public static let plans: [Plan] = [
        Plan(id: "individual-go", displayName: "Go", monthlyCreditsUSD: 10),
        Plan(id: "individual-pro", displayName: "Pro", monthlyCreditsUSD: 30),
        Plan(id: "individual-max", displayName: "Max", monthlyCreditsUSD: 150),
        Plan(id: "individual-ultra", displayName: "Ultra", monthlyCreditsUSD: 300),
    ]

    public static func plan(forID planID: String) -> Plan? {
        let normalized = planID.lowercased()
        return self.plans.first(where: { $0.id == normalized })
    }
}
