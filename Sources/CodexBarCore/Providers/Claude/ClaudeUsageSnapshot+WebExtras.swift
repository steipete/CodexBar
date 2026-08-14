extension ClaudeUsageSnapshot {
    func replacingWebExtras(
        extraRateWindows: [NamedRateWindow],
        providerCost: ProviderCostSnapshot?) -> ClaudeUsageSnapshot
    {
        ClaudeUsageSnapshot(
            primary: self.primary,
            primaryWindowKind: self.primaryWindowKind,
            secondary: self.secondary,
            opus: self.opus,
            extraRateWindows: extraRateWindows,
            providerCost: providerCost,
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
            oauthKeychainCredentialUnavailable: self.oauthKeychainCredentialUnavailable)
    }
}
