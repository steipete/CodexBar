import Foundation

enum ClaudeVerifiedAccountOwner {
    static func ownerID(accountUUID: String?, email: String?, organizationUUID: String?) -> String? {
        guard let organization = CodexIdentityResolver.normalizeAccountID(organizationUUID) else { return nil }
        let principal: [String]
        if let account = CodexIdentityResolver.normalizeAccountID(accountUUID) {
            principal = ["uuid", account]
        } else if let email = CodexIdentityResolver.normalizeEmail(email) {
            principal = ["email", email]
        } else {
            return nil
        }
        guard let data = try? JSONEncoder().encode(principal + [organization]) else { return nil }
        return "claude-owner-v1:" + ClaudeOAuthCredentialsStore.sha256Hex(data)
    }
}

extension ClaudeUsageSnapshot {
    func withAccountIdentity(_ accountID: String?, email: String? = nil) -> ClaudeUsageSnapshot {
        var snapshot = self
        snapshot.accountID = accountID
        snapshot.accountEmail = email ?? self.accountEmail
        return snapshot
    }
}
