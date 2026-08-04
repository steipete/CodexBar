import Foundation

public struct ProviderIdentitySnapshot: Codable, Sendable {
    public let providerID: ProviderInstanceID?
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let accountID: String?

    public init(
        providerID: ProviderInstanceID?,
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

    public func scoped(to instanceID: ProviderInstanceID) -> ProviderIdentitySnapshot {
        if self.providerID == instanceID {
            return self
        }
        return ProviderIdentitySnapshot(
            providerID: instanceID,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.loginMethod,
            accountID: self.accountID)
    }

    public func scoped(to provider: UsageProvider) -> ProviderIdentitySnapshot {
        self.scoped(to: provider.instanceID)
    }
}

public enum UsageDataConfidence: String, Codable, Equatable, Sendable {
    case exact
    case estimated
    case percentOnly
    case unknown
}
