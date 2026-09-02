import Foundation

public struct CodeRabbitUsageSnapshot: Sendable, Equatable {
    public let organization: String?
    public let user: String?
    public let accountEmail: String?
    public let plan: String?
    public let reviewsCount: Int?
    public let usageBilling: String?
    public let periodResets: Date?
    public let periodResetsRaw: String?
    public let updatedAt: Date

    public init(
        organization: String? = nil,
        user: String? = nil,
        accountEmail: String? = nil,
        plan: String? = nil,
        reviewsCount: Int? = nil,
        usageBilling: String? = nil,
        periodResets: Date? = nil,
        periodResetsRaw: String? = nil,
        updatedAt: Date = Date())
    {
        self.organization = organization
        self.user = user
        self.accountEmail = accountEmail
        self.plan = plan
        self.reviewsCount = reviewsCount
        self.usageBilling = usageBilling
        self.periodResets = periodResets
        self.periodResetsRaw = periodResetsRaw
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot(now: Date = Date()) -> UsageSnapshot {
        _ = now
        let identity = ProviderIdentitySnapshot(
            providerID: .coderabbit,
            accountEmail: self.accountEmail,
            accountOrganization: self.organization,
            loginMethod: self.makeLoginMethod())

        var rows: [ProviderDetailSection.Row] = []
        if let reviewsCount = self.reviewsCount {
            rows.append(.makeRow(label: "Reviews", value: "\(reviewsCount)"))
        }
        if let organization = self.organization, !organization.isEmpty {
            rows.append(.makeRow(label: "Organization", value: organization))
        }
        if let usageBilling = self.usageBilling, !usageBilling.isEmpty {
            rows.append(.makeRow(label: "Usage billing", value: usageBilling))
        }
        if let periodResetsRaw = self.periodResetsRaw, !periodResetsRaw.isEmpty {
            rows.append(.makeRow(label: "Period resets", value: periodResetsRaw))
        }

        let details: [ProviderDetailSection] = rows.isEmpty
            ? []
            : [.makeSection(title: "Billing", rows: rows)]

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            details: details,
            subscriptionRenewsAt: self.periodResets,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func makeLoginMethod() -> String? {
        var parts: [String] = []
        if let plan = self.plan, !plan.isEmpty {
            parts.append(plan)
        }
        if let reviewsCount = self.reviewsCount {
            parts.append("\(reviewsCount) \(reviewsCount == 1 ? "review" : "reviews")")
        }
        if parts.isEmpty {
            if self.organization != nil {
                return "CodeRabbit"
            }
            return nil
        }
        return parts.joined(separator: " · ")
    }
}
