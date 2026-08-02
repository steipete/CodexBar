import Foundation

public struct ProviderIdentitySnapshot: Codable, Sendable {
    public let providerID: UsageProvider?
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let accountID: String?

    public init(
        providerID: UsageProvider?,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?,
        accountID: String? = nil)
    {
        self.providerID = providerID
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
        self.accountID = accountID
    }

    public func scoped(to provider: UsageProvider) -> ProviderIdentitySnapshot {
        if self.providerID == provider {
            return self
        }
        return ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.loginMethod,
            accountID: self.accountID)
    }
}

public enum UsageDataConfidence: String, Codable, Equatable, Sendable {
    case exact
    case estimated
    case percentOnly
    case unknown
}
