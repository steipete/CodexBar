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
        let primary: RateWindow? = {
            if let periodResets {
                return RateWindow(
                    usedPercent: 0,
                    windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                    resetsAt: periodResets,
                    resetDescription: self.periodResetsRaw.map { "resets \($0)" })
            }
            return nil
        }()

        let identity = ProviderIdentitySnapshot(
            providerID: .coderabbit,
            accountEmail: self.accountEmail,
            accountOrganization: self.organization,
            loginMethod: self.plan ?? (self.organization != nil ? "CodeRabbit" : nil))

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
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            details: details,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
