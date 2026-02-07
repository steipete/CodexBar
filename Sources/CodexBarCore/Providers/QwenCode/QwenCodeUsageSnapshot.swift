import Foundation

public struct QwenCodeUsageSnapshot: Sendable {
    public let requests: Int
    public let totalTokens: Int
    public let windowStart: Date
    public let windowEnd: Date
    public let updatedAt: Date
    public let accountEmail: String?
    public let loginMethod: String?

    public init(
        requests: Int,
        totalTokens: Int,
        windowStart: Date,
        windowEnd: Date,
        updatedAt: Date,
        accountEmail: String?,
        loginMethod: String?)
    {
        self.requests = requests
        self.totalTokens = totalTokens
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.updatedAt = updatedAt
        self.accountEmail = accountEmail
        self.loginMethod = loginMethod
    }

    public func toUsageSnapshot(requestLimit: Int) -> UsageSnapshot {
        let usedPercent: Double = if requestLimit > 0 {
            min(100, max(0, (Double(self.requests) / Double(requestLimit)) * 100))
        } else {
            0
        }
        let resetDescription = UsageFormatter.resetDescription(from: self.windowEnd)
        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 24 * 60,
            resetsAt: self.windowEnd,
            resetDescription: resetDescription)

        let identity = ProviderIdentitySnapshot(
            providerID: .qwencode,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
