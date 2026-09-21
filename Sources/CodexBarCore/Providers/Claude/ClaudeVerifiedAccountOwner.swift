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
    func withAccountIdentity(_ accountID: String) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            primary: self.primary,
            primaryWindowKind: self.primaryWindowKind,
            secondary: self.secondary,
            opus: self.opus,
            extraRateWindows: self.extraRateWindows,
            providerCost: self.providerCost,
            updatedAt: self.updatedAt,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.loginMethod,
            rawText: self.rawText,
            oauthKeychainPersistentRefHash: self.oauthKeychainPersistentRefHash,
            oauthHistoryOwnerIdentifier: self.oauthHistoryOwnerIdentifier,
            oauthCredentialOwner: self.oauthCredentialOwner,
            oauthKeychainCredentialMismatch: self.oauthKeychainCredentialMismatch,
            oauthKeychainCredentialAbsent: self.oauthKeychainCredentialAbsent,
            oauthKeychainCredentialUnavailable: self.oauthKeychainCredentialUnavailable,
            accountID: accountID)
    }
}
