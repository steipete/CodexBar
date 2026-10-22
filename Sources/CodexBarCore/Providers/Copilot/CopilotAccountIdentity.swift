import Foundation

public enum CopilotAccountIdentity {
    public static func matchExistingAccount(
        existingAccounts: [ProviderTokenAccount],
        identity: CopilotUsageFetcher.GitHubUserIdentity?,
        label: String,
        issuer: String = "api.github.com",
        legacyIdentityResolver: @escaping @Sendable (ProviderTokenAccount) async
            -> CopilotUsageFetcher.GitHubUserIdentity? = { account in
                try? await CopilotUsageFetcher.fetchGitHubIdentity(token: account.token)
            }) async -> ProviderTokenAccount?
    {
        guard let identity, !existingAccounts.isEmpty else { return nil }
        let stableIdentifier = self.externalIdentifier(for: identity, issuer: issuer)
        let login = self.normalizedGitHubLogin(identity.login)

        if let byID = existingAccounts.first(where: { account in
            self.normalizedExternalIdentifier(account.externalIdentifier) == stableIdentifier
        }) {
            return byID
        }

        // Hostless legacy identifiers belong to the existing public-GitHub path.
        guard issuer == "api.github.com" else { return nil }

        // Previous PR revisions stored GitHub login in externalIdentifier. Keep matching those
        // accounts case-insensitively, then write back the stable ID on update.
        if let byLegacyLogin = existingAccounts.first(where: { account in
            self.normalizedGitHubLogin(account.externalIdentifier) == login
        }) {
            return byLegacyLogin
        }

        var labelFallback: ProviderTokenAccount?
        for account in existingAccounts where account.externalIdentifier == nil {
            if let resolvedIdentity = await legacyIdentityResolver(account) {
                if resolvedIdentity.id == identity.id {
                    return account
                }
            } else if labelFallback == nil,
                      self.displayLabelPrefix(account.label) == self.displayLabelPrefix(label)
            {
                labelFallback = account
            }
        }
        return labelFallback
    }

    public static func externalIdentifier(
        for identity: CopilotUsageFetcher.GitHubUserIdentity,
        issuer: String = "api.github.com") -> String
    {
        issuer == "api.github.com" ? "github:user:\(identity.id)" : "github:\(issuer):user:\(identity.id)"
    }

    private static func normalizedExternalIdentifier(_ identifier: String?) -> String? {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func normalizedGitHubLogin(_ login: String?) -> String? {
        guard let normalized = self.normalizedExternalIdentifier(login), !normalized.hasPrefix("github:")
        else { return nil }
        return normalized
    }

    private static func displayLabelPrefix(_ label: String) -> String {
        (label.components(separatedBy: " (").first ?? label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
