import Foundation

public struct MuseUsageSnapshot: Sendable, Equatable {
    /// Tokens-per-minute window, from `x-ratelimit-*-tokens`.
    public let primary: RateWindow?
    /// Requests-per-minute window, from `x-ratelimit-*-requests`.
    public let secondary: RateWindow?
    public let accountEmail: String?
    public let plan: String?
    public let updatedAt: Date

    public init(
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        accountEmail: String? = nil,
        plan: String? = nil,
        updatedAt: Date = Date())
    {
        self.primary = primary
        self.secondary = secondary
        self.accountEmail = accountEmail
        self.plan = plan
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.plan)
        return UsageSnapshot(
            primary: self.primary,
            secondary: self.secondary,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
