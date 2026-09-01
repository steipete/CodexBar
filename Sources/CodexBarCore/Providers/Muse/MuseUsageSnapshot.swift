import Foundation

public struct MuseUsageSnapshot: Sendable {
    public let primary: RateWindow?
    public let secondary: RateWindow?
    public let tertiary: RateWindow?
    public let accountEmail: String?
    public let plan: String?
    public let updatedAt: Date

    public init(
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        accountEmail: String? = nil,
        plan: String? = nil,
        updatedAt: Date = Date())
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.accountEmail = accountEmail
        self.plan = plan
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.plan ?? "API Key")
        return UsageSnapshot(
            primary: self.primary,
            secondary: self.secondary,
            tertiary: self.tertiary,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
