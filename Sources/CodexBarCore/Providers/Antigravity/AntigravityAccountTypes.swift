import Foundation

/// Represents stored Antigravity account data for multi-account support.
public struct AntigravityAccountData: Codable, Sendable {
    public let version: Int
    public let accounts: [AntigravityAccount]
    public let activeIndex: Int
    public let activeIndexByFamily: [String: Int]

    public init(
        version: Int,
        accounts: [AntigravityAccount],
        activeIndex: Int,
        activeIndexByFamily: [String: Int])
    {
        self.version = version
        self.accounts = accounts
        self.activeIndex = activeIndex
        self.activeIndexByFamily = activeIndexByFamily
    }
}

/// A single Antigravity account with credentials and rate limit tracking.
public struct AntigravityAccount: Codable, Sendable {
    public let email: String
    public let refreshToken: String
    public let projectId: String?
    public let addedAt: TimeInterval
    public let lastUsed: TimeInterval?
    public let rateLimitResetTimes: [String: TimeInterval]
    public let coolingDownUntil: TimeInterval?
    public let cooldownReason: String?

    public var displayName: String {
        self.email
    }

    public var refreshTokenWithProjectId: String {
        if let projectId = self.projectId, !projectId.isEmpty {
            return "\(self.refreshToken)|\(projectId)"
        }
        return "\(self.refreshToken)|"
    }

    public init(
        email: String,
        refreshToken: String,
        projectId: String?,
        addedAt: TimeInterval,
        lastUsed: TimeInterval?,
        rateLimitResetTimes: [String: TimeInterval],
        coolingDownUntil: TimeInterval?,
        cooldownReason: String?)
    {
        self.email = email
        self.refreshToken = refreshToken
        self.projectId = projectId
        self.addedAt = addedAt
        self.lastUsed = lastUsed
        self.rateLimitResetTimes = rateLimitResetTimes
        self.coolingDownUntil = coolingDownUntil
        self.cooldownReason = cooldownReason
    }
}
