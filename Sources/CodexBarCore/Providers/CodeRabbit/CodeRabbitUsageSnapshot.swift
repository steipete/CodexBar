import Foundation

public struct CodeRabbitUsageSnapshot: Sendable, Equatable {
    public let organization: String?
    public let user: String?
    public let plan: String?
    public let reviewsCount: Int?
    public let usageBilling: String?
    public let periodResets: String?
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        var rows: [ProviderDetailSection.Row] = []
        if let reviewsCount { rows.append(.makeRow(label: "Reviews", value: "\(reviewsCount)")) }
        if let usageBilling { rows.append(.makeRow(label: "Usage billing", value: usageBilling)) }
        if let periodResets { rows.append(.makeRow(label: "Period resets", value: periodResets)) }
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [.makeSection(title: "Billing", rows: rows)],
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .coderabbit,
                accountEmail: nil,
                accountOrganization: self.organization,
                loginMethod: self.plan,
                accountID: self.user))
    }
}
