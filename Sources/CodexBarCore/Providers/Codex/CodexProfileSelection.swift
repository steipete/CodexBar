import Foundation

public struct CodexProfileSelection: Codable, Sendable, Equatable {
    public let alias: String
    public let profilePath: String
    public let accountEmail: String?
    public let accountID: String?
    public let plan: String?

    public init(
        alias: String,
        profilePath: String,
        accountEmail: String?,
        accountID: String?,
        plan: String?)
    {
        self.alias = alias
        self.profilePath = profilePath
        self.accountEmail = accountEmail
        self.accountID = accountID
        self.plan = plan
    }
}
